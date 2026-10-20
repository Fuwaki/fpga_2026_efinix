/*******************************************************************************
 * camera_i2c - SC431HAI 摄像头 I2C 初始化 (由 RISC-V 执行)
 *
 * 参考工程 (Ti60f225_sc431hai2hdmi_v6) 里，摄像头寄存器表由 FPGA 侧的
 * i2c_master_reg_rom 顺序播放。本工程把这件工作交给 Sapphire RV32 SoC：
 * 固件启动后通过 I2C0 把 sc431hai_regs.h 里的寄存器表写下去，然后点亮
 * 指示灯并停住。FPGA 侧不再有任何 I2C 主机。
 *
 * 硬件约定 (见 rtl/fpga_src_top.v):
 *   system_gpio_0_io_write[0] -> led[1]  : 0 = 正在配置/失败, 1 = 配置完成
 ******************************************************************************/
#include <stdint.h>
#include "bsp.h"
#include "i2c.h"
#include "gpio.h"
#include "sc431hai_regs.h"
#include "userDef.h"

/* 想通过串口看进度就打开；本板 UART 未引出，打开只会白等波特率时间 */
#define CAM_I2C_VERBOSE 1

#define LED_DONE_MASK 0x1u   /* GPIO0[0] -> led[1] */
#define ST_DBG_BASE   IO_APB_SLAVE_0_INPUT
#define ST_DBG32(off) (*(volatile uint32_t *)(ST_DBG_BASE + (off)))

static void camLed(u32 on)
{
    gpio_setOutput(GPIO_CTRL, on ? LED_DONE_MASK : 0u);
}

static void camI2cInit(void)
{
    I2c_Config i2c;
    i2c.samplingClockDivider = 3;
    i2c.timeout              = I2C_CTRL_HZ / 10;                 /* 0.1 s 无响应即放弃 */
    i2c.tsuDat               = I2C_CTRL_HZ / I2C_FREQUENCY / 3;
    i2c.tLow                 = I2C_CTRL_HZ / I2C_FREQUENCY / 2;
    i2c.tHigh                = I2C_CTRL_HZ / I2C_FREQUENCY / 2;
    i2c.tBuf                 = I2C_CTRL_HZ / I2C_FREQUENCY;
    i2c_applyConfig(I2C_CTRL, &i2c);
}

void main(void)
{
    bsp_init();

    gpio_setOutputEnable(GPIO_CTRL, LED_DONE_MASK);
    camLed(0);

    camI2cInit();

#if CAM_I2C_VERBOSE
    bsp_printf("\r\n[camera_i2c] SC431HAI init, %d registers @ %d Hz\r\n",
               SC431HAI_REG_COUNT, I2C_FREQUENCY);
#endif

    /* 寄存器写入顺序与参考工程 FPFA 侧 ROM 完全一致，禁止重排。
     * 表首的 0x0103=0x01 是软复位：厂商表假设芯片刚出复位，而本工程是在
     * 一颗可能已跑过上一套配置的芯片上热写，不复位会残留旧的裁切窗口。
     * 数据手册要求复位保持 150 ns 以上，所以遇到它就停一会儿。 */
    for (u32 i = 0; i < SC431HAI_REG_COUNT; i++) {
        u8 d = sc431hai_regs[i].data;
        i2c_writeData_w(I2C_CTRL, SC431HAI_I2C_ADDR, sc431hai_regs[i].addr, &d, 1);

        if (sc431hai_regs[i].addr == 0x0103) {
            for (volatile u32 settle = 0; settle < 200; ++settle)
                __asm__ volatile ("nop");
        }
    }

    /* The driver API returns void and its _ack variants bail out silently, so
     * the only way to know the bus answered is to read something back.  The
     * chip ID at 0x3107 is 16 bit big-endian, 0xCD6B on SC431HAI (see
     * SC431HAI_REG_VALUE_16BIT in the vendor driver).  Previously the
     * "configured" LED was set with no check at all, which let the telemetry
     * status bit claim success while nothing had been written. */
    u8 id[2] = {0x00, 0x00};
    i2c_readData_w(I2C_CTRL, SC431HAI_I2C_ADDR, 0x3107, id, 2);
    u32 chip_ok = (id[0] == 0xCD) && (id[1] == 0x6B);

#if CAM_I2C_VERBOSE
    bsp_printf("[camera_i2c] done, chip id %02x%02x %s\r\n",
               id[0], id[1], chip_ok ? "ok" : "MISMATCH");
#endif

    camLed(chip_ok);

    while (1) {
        /* CPU 作为板上调试跳板：读取硬件 tile 管线的 APB 只读窗口。 */
        uint32_t hb = ST_DBG32(0x54) + 1u;
        ST_DBG32(0x54) = hb;
        bsp_printf("[st] cap=%x tiles=%x commit=%x xy=%x addr=%x state=%x hb=%x\r\n",
                   ST_DBG32(0x40), ST_DBG32(0x44), ST_DBG32(0x48),
                   ST_DBG32(0x4c), ST_DBG32(0x50), ST_DBG32(0x34), hb);
        for (volatile uint32_t delay = 0; delay < 5000000u; ++delay) {
            __asm__ volatile ("nop");
        }
    }
}
