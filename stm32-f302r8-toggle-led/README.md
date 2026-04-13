## toggle led
Press B1 (PC13) to toggle LD2 (PB13) between ON/OFF states.
Prints `ON` or `OFF` over USART2 (PA2 TX, 115200 8N1).

### Hardware
- Board: STM32-NUCLEO-F302R8
- LED: LD2 on PB13
- Button: B1 on PC13 (active low)
- UART: PA2 TX → ST-LINK virtual COM port

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
