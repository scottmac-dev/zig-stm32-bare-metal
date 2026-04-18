## button count with EXTI interrupt
Press B1 (PC13) to trigger EXTI interrupt
Interrupt handler fires and increments a counter + sets a flag 
Main loop sees flag set and emits COUNT: N over UART then clears flag

### Hardware
- Board: STM32-NUCLEO-F302R8
- LED: LD2 on PB13
- Button: B1 on PC13 (active low)
- UART: PA2 TX → ST-LINK virtual COM port

### Conceptual interactions 
- USER B1 pressed, PC13 register pulled low 1 -> 0
- EXTI line 13 detects falling edge 
- EXTI signals the NVIC
- NVIC interrupts the CPU 
- CPU jumps to handler logic 
- Handler runs, increments counter, flips flag 
- CPU resumes, super loop sees flag set, sends count over UART, clears flag

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
