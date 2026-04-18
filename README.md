# zig-stm32-bare-metal
A collection of bare metal zig on STM32 MCU examples

## STM32-NUCELO-F302R8
[Hardware Details](https://www.st.com/en/evaluation-tools/nucleo-f302r8.html)

Examples
- **blinky:** blink green LD2 led on devboard in constant cycle
- **toggle led:** toggle green LD2 led with blue B1 USER button and print state via UART
- **systick:** blink green LD2 led on devboard using Cortex-M SysTick peripheral instead of primitive `noop` loop
- **button count w\ interrupt:** pressing B1 USER button triggers EXTI interrupt and increments a counter, counter tally is transmitted over UART
- **pulse modulation mg996r servo sweep:**  sweep MG996R servo motor across full range using TIM1 hardware PWM, no CPU involvement once configured

### Other hardware referenced
- [MG996R](https://www.aliexpress.com/item/1005010238268698.html?src=google)
  servo motor
