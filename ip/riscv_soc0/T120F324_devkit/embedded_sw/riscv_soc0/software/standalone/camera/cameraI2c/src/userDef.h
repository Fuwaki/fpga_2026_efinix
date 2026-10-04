/*******************************************************************************
 * userDef.h - camera_i2c 用到的外设基址/频率
 ******************************************************************************/
#pragma once

#ifdef SYSTEM_I2C_0_IO_CTRL
    #define I2C_CTRL            SYSTEM_I2C_0_IO_CTRL
    #define I2C_CTRL_PLIC_INTERRUPT SYSTEM_PLIC_SYSTEM_I2C_0_IO_INTERRUPT
#endif

#ifdef SYSTEM_GPIO_0_IO_CTRL
    #define GPIO_CTRL           SYSTEM_GPIO_0_IO_CTRL
#endif

#define I2C_CTRL_HZ         SYSTEM_CLINT_HZ   /* SoC Frequency = 100 MHz */
#define I2C_FREQUENCY       100000            /* 100 kHz 标准模式 */
