/*******************************************************************************
 * isp_ctrl.c - 自动白平衡 (AWB) 和自动曝光 (AE)
 *
 * FPGA 侧只做两件事 (rtl/ui_regs.sv):
 *   - isp_stats 每帧统计 4 个 Bayer 相位的原始值之和, 以及过曝/过暗像素数;
 *   - isp_blc_wb 用固件写入的 R/G/B 增益 (Q4.8, 已含黑电平拉伸), 帧起始时生效.
 * 计算全部在这里.
 *
 * AWB (灰世界): 每个颜色的增益 = T / m_c, m_c 是减去黑电平后的均值.
 *   三个通道输出均值都拉到 T, 所以这一步同时完成白平衡和亮度的细调.
 *   每帧只向目标走 1/4, 避免跳色.
 * AE: 只调传感器曝光 (0x3E00-02), 不动模拟增益 (保持寄存器表的约 2x).
 *   让 G 的原始均值接近 2T, 这样 G 增益约 0.5, R/B 增益约 1 附近, 和原来的
 *   固定白平衡同一个工作点.  曝光 >= 10 ms 时取 10 ms 的整数倍 (50 Hz 灯光
 *   不出条纹), 最长 40 ms.  剩下的亮度误差由上面的数字增益吸收.
 *   改曝光后等 3 帧再看, 传感器要 1-2 帧才生效.
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
#define REG_FRAMES      0x8028u

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
/* 偏色微调 (Q8, 256 = 中性): 想让画面整体偏冷就把 B 调大一点. */
#define BIAS_R         256u
#define BIAS_B         256u

#define GAIN_MIN       32u          /* 0.125x */
#define GAIN_MAX       1023u        /* 4x, 再大噪声太明显 */

/* 曝光单位是半行: 4922 半行 = 40 ms (sc431hai_regs.h). */
#define EXP_40MS       4922u
#define EXP_MIN        8u
#define AE_SETTLE      3u           /* 改曝光后跳过的帧数 */

static uint32_t g_q8[3];            /* 当前增益 R, G, B */
static uint32_t exp_hl = EXP_40MS;  /* 当前曝光, 半行 */
static uint32_t frames_seen;
static uint32_t ae_wait;

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

void isp_ctrl_init(void)
{
    uint32_t rg = UI32(REG_GAIN_RG);
    g_q8[0] = rg & 0xFFFu;
    g_q8[1] = (rg >> 16) & 0xFFFu;
    g_q8[2] = UI32(REG_GAIN_B) & 0xFFFu;
    exp_hl = EXP_40MS;
    frames_seen = UI32(REG_FRAMES) & 0xFFu;
    ae_wait = AE_SETTLE;
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
    if ((UI32(REG_FRAMES) & 0xFFu) != f0)           /* 读的时候换了帧, 下次再来 */
        return;
    frames_seen = f0;

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

    /* AWB + 亮度: 画面几乎全黑时不动, 避免把噪声拉成大增益 */
    if (m[0] < 4u || m[1] < 4u || m[2] < 4u)
        return;
    const uint32_t bias[3] = { BIAS_R, 256u, BIAS_B };
    for (uint32_t c = 0; c < 3u; c++) {
        uint32_t tgt = clampu((T_OUT * bias[c]) / m[c], GAIN_MIN, GAIN_MAX);
        int32_t d = (int32_t)tgt - (int32_t)g_q8[c];
        g_q8[c] = (uint32_t)((int32_t)g_q8[c] + d / 4);
        if (d != 0 && d / 4 == 0) g_q8[c] += d > 0 ? 1u : (uint32_t)-1;
    }
    gains_write();
}
