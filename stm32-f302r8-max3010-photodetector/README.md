## MAX3010 Photodetector Sensor

### Hardware
- Board: STM32-NUCLEO-F302R8
- Jumper wires + Breadboard (optional can do direct wiring)

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### Physical Wiring

### Concptual interactions

### Toolchain
- Zig 0.17.0-dev nightly
- STM32CubeProgrammer (flashing)
- PuTTY (serial monitor)
