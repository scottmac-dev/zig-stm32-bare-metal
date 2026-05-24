## IMU and LCD ouput


### Hardware
- Board: STM32-NUCLEO-F302R8
- LED: LD2 on PB13

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### Toolchain
- Zig 0.17.0-dev nightly
- STM32CubeProgrammer (flashing)
- PuTTY (serial monitor)
