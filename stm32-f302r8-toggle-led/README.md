## toggle led
Press B1 (PC13) to toggle LD2 (PB13) between ON/OFF states.
Prints `ON` or `OFF` over USART2 (PA2 TX, 115200 8N1).

### Hardware
- Board: STM32-NUCLEO-F302R8
- LED: LD2 on PB13
- Button: B1 on PC13 (active low)
- UART: PA2 TX → ST-LINK virtual COM port

### Conceptual interaction
- Super loop running 
- Checks USER B1 button for current state 
- If state has changed (pulled low to 0) and differs from last state
    - Flip the armed flag
        - If armed, write to PB13 to turn on led    
        - Else reset PB13 to turn off led
        - Spin for 200,000 cycles for time delay padding 
- Save the current state and spin for 80,000 cycles for time delay

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### UART Monitor
Open PuTTY on the ST-LINK COM port at 115200 baud before resetting the board.

### Toolchain
- Zig 0.16.0-dev nightly
- STM32CubeProgrammer (flashing)
- PuTTY (serial monitor)
