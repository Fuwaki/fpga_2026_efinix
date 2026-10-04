/*******************************************************************************
 * camera_i2c - SC431HAI 摄像头 I2C 初始化 (由 RISC-V 执行)
 *
 * 参考工程 (Ti60f225_sc431hai2hdmi_v6) 里，摄像头寄存器表由 FPGA 侧的
 * i2c_master_reg_rom 顺序播放。本工程把这件工作交给 Sapphire RV32 SoC：
 * 固件启动后通过 I2C0 把 sc431hai_regs.h 里的 164 条寄存器写下去，然后点亮
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
#define CAM_I2C_VERBOSE 0

#define LED_DONE_MASK 0x1u   /* GPIO0[0] -> led[1] */

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

    /* GPIO0[0] 输出，初始为 0（配置中） */
    gpio_setOutputEnable(GPIO_CTRL, LED_DONE_MASK);
    camLed(0);

    camI2cInit();

#if CAM_I2C_VERBOSE
    bsp_printf("\r\n[camera_i2c] SC431HAI init, %d registers @ %d Hz\r\n",
               SC431HAI_REG_COUNT, I2C_FREQUENCY);
#endif

    /* 寄存器写入顺序与参考工程 FPFA 侧 ROM 完全一致，禁止重排 */
    for (u32 i = 0; i < SC431HAI_REG_COUNT; i++) {
        u8 d = sc431hai_regs[i].data;
        i2c_writeData_w(I2C_CTRL, SC431HAI_I2C_ADDR, sc431hai_regs[i].addr, &d, 1);
    }

#if CAM_I2C_VERBOSE
    bsp_printf("[camera_i2c] done\r\n");
#endif

    camLed(1);      /* 配置完成 */

    while (1) {
        /* 后续按键/状态逻辑挂在这里 */
    }
}
