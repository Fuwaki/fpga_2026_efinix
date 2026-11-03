/*******************************************************************************
 * isp_ctrl.c - 自动白平衡 (AWB) 和自动曝光 (AE)
 *
 * FPGA 侧只做两件事 (rtl/ui_regs.sv):
 *   - isp_stats 每帧统计 4 个 Bayer 相位的原始值之和, 以及过曝/过暗像素数;
 *   - isp_blc_wb 用固件写入的 R/G/B 增益 (Q4.8, 已含黑电平拉伸), 帧起始时生效.
 * 计算全部在这里.
 *
 * 亮度: G 增益 = T / m_g, m_g 是 G 减去黑电平后的均值.
 * AWB (灰像素): 光源颜色用 rg、bg (原始 R/G、B/G) 表示, R、B 增益是 G 增益
 *   除以它们.  isp_gray_stats 在白平衡之后统计"接近灰色"的像素 (R、B 和 G 相差
 *   不到 3/16, 不太暗也不过曝) 的 R、G、B 之和.  白平衡对的话三者相等; 不等时
 *   比值就是剩余的偏色, 光源估计乘上它.  手、木桌这类有颜色的物体不会被算进去,
 *   所以不会像全画面灰世界那样把它们拉成灰色.  近灰像素太少 (画面里没有灰色
 *   的东西) 时光源估计保持不变, 只调亮度.  光源估计限制在合理范围 (RG_*, BG_*).
 *   光源估计和增益每帧都只向目标走 1/4, 避免跳色.
 * AE: 只调传感器曝光 (0x3E00-02), 不动模拟增益 (保持寄存器表的约 2x).
 *   让 G 的原始均值接近 2T, 这样 G 增益约 0.5, R/B 增益约 1 附近, 和原来的
 *   固定白平衡同一个工作点.  曝光 >= 10 ms 时取 10 ms 的整数倍 (50 Hz 灯光
 *   不出条纹), 最长 40 ms.  剩下的亮度误差由上面的数字增益吸收.
 *   改曝光后等 3 帧再看, 传感器要 1-2 帧才生效.
 * 白纸标定 (KEY1): 短按 = 对着占满画面的白纸, 取 4 帧整帧原始统计的 R/G、B/G
 *   直接作为光源估计, 并锁定 (不再用灰像素更新).  长按约 1 秒 = 回到自动.
 *   过曝超过 2% 的帧不用, 等 AE 先把曝光降下来.  锁定时 AE 和亮度照常.
 ******************************************************************************/
#include <stdint.h>
#include "bsp.h"
#include "i2c.h"
#include "sc431hai_regs.h"
#include "userDef.h"
#include "isp_ctrl.h"

#define UI32(off)       (*(volatile uint32_t *)(IO_APB_SLAVE_0_INPUT + (off)))
#define REG_GAIN_RG     0x8008u
#define REG_GAIN_B      0x800Cu
#define REG_SUM(k)      (0x8010u + 4u * (k))
#define REG_CLIP        0x8020u
#define REG_KEY1        0x8024u
#define REG_FRAMES      0x8028u
#define REG_GRAY(k)     (0x802Cu + 4u * (k))  /* R, G, B (各取高 8 位) 之和 */

/* cfa_r = 2'b10 (rtl/vid/common/vid_pkg.sv): 统计按 {行奇偶, 列奇偶} 编号,
 * R 在 {1,0} = 2, B 在 {0,1} = 1, G 在 0 和 3. */
#define PH_R 2u
#define PH_B 1u
#define PH_G0 0u
#define PH_G1 3u

#define BLC            64u          /* 10 位原始值的黑电平, 同 ISP_CFG.blc_level */
#define PIX_PER_PHASE  (1280u * 720u / 4u)
#define PIX_ALL        (1280u * 720u)

/* 输出目标: 增益后的线性 10 位均值.  上板前固定白平衡下实测约 140. */
#define T_OUT          150u
/* 合理的光源范围, Q8 (256 = 1.0).  中心约是办公室灯光下实测的 rg 0.64、bg 0.47,
 * 各放宽约 25%.  只是兜底: 光源估计不会被拉出这个范围. */
#define RG_MIN         115u         /* 0.45 */
#define RG_MAX         205u         /* 0.80 */
#define BG_MIN         90u          /* 0.35 */
#define BG_MAX         166u         /* 0.65 */

/* 近灰像素的 G (高 8 位) 之和至少这么大才更新光源: 约 2000 个中等亮度的像素
 * (偶数列共 460800 个). */
#define GRAY_G_MIN     (2000u * 32u)

#define GAIN_MIN       32u          /* 0.125x */
#define GAIN_MAX       1023u        /* 4x, 再大噪声太明显 */

/* 曝光单位是半行: 4922 半行 = 40 ms (sc431hai_regs.h). */
#define EXP_40MS       4922u
#define EXP_MIN        8u
#define AE_SETTLE      3u           /* 改曝光后跳过的帧数 */

#define CAL_FRAMES     4u           /* 白纸标定累加的帧数 */
#define LONG_FRAMES    20u          /* KEY1 按住这么多帧 (约 1 s) 算长按 */
#define CAL_MIN        64u          /* 白纸标定的光源范围, Q8, 比自动的范围宽 */
#define CAL_MAX        512u

static uint32_t g_q8[3];            /* 当前增益 R, G, B */
static uint32_t rg_q8, bg_q8;       /* 光源估计 */
static uint32_t exp_hl = EXP_40MS;  /* 当前曝光, 半行 */
static uint32_t frames_seen;
static uint32_t ae_wait;
static uint32_t wb_lock;            /* 1: 白纸标定后锁定 */
static uint32_t cal_left;           /* 白纸标定还要累加的帧数, 0: 不在标定 */
static uint32_t cal_r, cal_g, cal_b;
static uint32_t key_frames;         /* KEY1 按住了几帧, 0: 没按 */

static void gains_write(void)
{
    UI32(REG_GAIN_RG) = (g_q8[1] << 16) | g_q8[0];
    UI32(REG_GAIN_B)  = g_q8[2];
}

static void exp_write(uint32_t e)
{
    u8 v[3] = { (u8)((e >> 12) & 0x0Fu), (u8)(e >> 4), (u8)(e << 4) };
    i2c_writeData_w(I2C_CTRL, SC431HAI_I2C_ADDR, 0x3E00, &v[0], 1);
    i2c_writeData_w(I2C_CTRL, SC431HAI_I2C_ADDR, 0x3E01, &v[1], 1);
    i2c_writeData_w(I2C_CTRL, SC431HAI_I2C_ADDR, 0x3E02, &v[2], 1);
}

static uint32_t clampu(uint32_t v, uint32_t lo, uint32_t hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* 向 tgt 走 1/4, 至少 1 */
static uint32_t step(uint32_t cur, uint32_t tgt)
{
    int32_t d = (int32_t)tgt - (int32_t)cur;
    int32_t q = d / 4;
    if (q == 0 && d != 0) q = d > 0 ? 1 : -1;
    return (uint32_t)((int32_t)cur + q);
}

void isp_ctrl_init(void)
{
    uint32_t rg = UI32(REG_GAIN_RG);
    g_q8[0] = rg & 0xFFFu;
    g_q8[1] = (rg >> 16) & 0xFFFu;
    g_q8[2] = UI32(REG_GAIN_B) & 0xFFFu;
    rg_q8 = clampu((256u * g_q8[1]) / g_q8[0], RG_MIN, RG_MAX);
    bg_q8 = clampu((256u * g_q8[1]) / g_q8[2], BG_MIN, BG_MAX);
    exp_hl = EXP_40MS;
    frames_seen = UI32(REG_FRAMES) & 0xFFu;
    ae_wait = AE_SETTLE;
    wb_lock = 0u;
    cal_left = 0u;
    key_frames = 0u;
}

/* KEY1 每个新帧采样一次, 松开时按按住的帧数区分短按和长按. */
static void key1_frame(void)
{
    if (UI32(REG_KEY1) & 1u) {
        if (key_frames < 255u) key_frames++;
        return;
    }
    if (key_frames == 0u)
        return;
    if (key_frames >= LONG_FRAMES) {
        wb_lock = 0u;
        cal_left = 0u;
        bsp_printf("[awb] auto\r\n");
    } else {
        cal_left = CAL_FRAMES;
        cal_r = cal_g = cal_b = 0u;
    }
    key_frames = 0u;
}

/* 新曝光: 按 G 均值和目标的比例缩放, 每步最多 2 倍; >= 10 ms 时取 10 ms 整数倍. */
static uint32_t ae_next(uint32_t e, uint32_t m_g, uint32_t clip)
{
    uint32_t want = 2u * T_OUT;
    uint32_t n;

    /* 死区: 差 25% 以内不动, 交给数字增益.  过曝超过 2% 时一定往下调. */
    if (clip * 50u <= PIX_ALL && m_g * 4u >= want * 3u && m_g * 4u <= want * 5u)
        return e;
    if (m_g < 1u) m_g = 1u;
    n = (e * want) / m_g;                           /* e <= 4922, 不会溢出 */
    if (clip * 50u > PIX_ALL && n >= e) n = e - e / 4u;
    n = clampu(n, e / 2u, e * 2u);
    n = clampu(n, EXP_MIN, EXP_40MS);
    if (n * 4u >= EXP_40MS) {                       /* >= 10 ms */
        uint32_t k = (n * 4u) / EXP_40MS;           /* 10 ms 的个数, 向下取整 */
        n = (k * EXP_40MS) / 4u;
    }
    return n;
}

void isp_ctrl_poll(void)
{
    uint32_t f0 = UI32(REG_FRAMES) & 0xFFu;
    if (f0 == frames_seen)
        return;

    uint32_t s[4];
    for (uint32_t k = 0; k < 4u; k++)
        s[k] = UI32(REG_SUM(k));
    uint32_t clip = UI32(REG_CLIP);
    uint32_t gs[3];
    for (uint32_t k = 0; k < 3u; k++)
        gs[k] = UI32(REG_GRAY(k));
    if ((UI32(REG_FRAMES) & 0xFFu) != f0)           /* 读的时候换了帧, 下次再来 */
        return;
    frames_seen = f0;
    key1_frame();

    /* 减黑电平后的均值 */
    uint32_t m[3];
    uint32_t raw_r = s[PH_R] / PIX_PER_PHASE;
    uint32_t raw_b = s[PH_B] / PIX_PER_PHASE;
    uint32_t raw_g = (s[PH_G0] / 2u + s[PH_G1] / 2u) / PIX_PER_PHASE;
    m[0] = raw_r > BLC ? raw_r - BLC : 0u;
    m[1] = raw_g > BLC ? raw_g - BLC : 0u;
    m[2] = raw_b > BLC ? raw_b - BLC : 0u;

    /* AE */
    if (ae_wait) {
        ae_wait--;
    } else {
        uint32_t e = ae_next(exp_hl, m[1], clip);
        if (e != exp_hl) {
            exp_hl = e;
            exp_write(e);
            ae_wait = AE_SETTLE;
        }
    }

    /* 画面几乎全黑时不动, 避免把噪声拉成大增益 */
    if (m[0] < 4u || m[1] < 4u || m[2] < 4u)
        return;

    /* 白纸标定: 整帧都是白纸, 减黑电平后的 R/G、B/G 就是光源颜色.
     * 每帧的和 < 2^28, 右移 4 位再累加 4 帧不会溢出. */
    if (cal_left && clip * 50u <= PIX_ALL) {
        uint32_t blc = BLC * PIX_PER_PHASE;
        uint32_t sg = s[PH_G0] / 2u + s[PH_G1] / 2u;
        cal_r += (s[PH_R] > blc ? s[PH_R] - blc : 0u) >> 4;
        cal_g += (sg > blc ? sg - blc : 0u) >> 4;
        cal_b += (s[PH_B] > blc ? s[PH_B] - blc : 0u) >> 4;
        if (--cal_left == 0u && (cal_g >> 8) > 0u) {
            rg_q8 = clampu(cal_r / (cal_g >> 8), CAL_MIN, CAL_MAX);
            bg_q8 = clampu(cal_b / (cal_g >> 8), CAL_MIN, CAL_MAX);
            wb_lock = 1u;
            bsp_printf("[awb] white rg=%d bg=%d (/256), locked\r\n", rg_q8, bg_q8);
        }
    }

    /* 光源估计: 近灰像素的剩余偏色 (Q8) 乘到估计上.  gs < 2^27, gs[1] >> 8 >= 250 */
    if (!wb_lock && !cal_left && gs[1] >= GRAY_G_MIN) {
        uint32_t res_r = gs[0] / (gs[1] >> 8);
        uint32_t res_b = gs[2] / (gs[1] >> 8);
        rg_q8 = step(rg_q8, clampu((rg_q8 * res_r) >> 8, RG_MIN, RG_MAX));
        bg_q8 = step(bg_q8, clampu((bg_q8 * res_b) >> 8, BG_MIN, BG_MAX));
    }

    uint32_t gg = clampu((T_OUT * 256u) / m[1], GAIN_MIN, GAIN_MAX);
    uint32_t tgt[3] = {
        clampu((gg * 256u) / rg_q8, GAIN_MIN, GAIN_MAX),
        gg,
        clampu((gg * 256u) / bg_q8, GAIN_MIN, GAIN_MAX),
    };
    for (uint32_t c = 0; c < 3u; c++)
        g_q8[c] = step(g_q8[c], tgt[c]);
    gains_write();
}
