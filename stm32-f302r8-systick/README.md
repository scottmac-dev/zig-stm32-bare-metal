## systick
Toggles LD2 (PB13) every 1 second using the Cortex-M SysTick peripheral.
Demonstrates non-blocking timing and shared state between an interrupt handler
and the main loop, replacing the NOP busy-wait delay used in the blinky example.

### Hardware
- Board: STM32-NUCLEO-F302R8
- LED: LD2 on PB13

### Timing
Interval = RVR / clock_speed. If you reconfigure the PLL the RVR value
must be updated to maintain 1ms ticks.

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### Toolchain
- Zig 0.16.0-dev nightly
- STM32CubeProgrammer (flashing)
