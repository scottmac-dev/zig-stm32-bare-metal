## MAX3010 Photodetector Sensor

### Hardware
- Board: STM32-NUCLEO-F302R8
- Breakout: MAX30101 Photodetector Breakout
- Jumper wires + Breadboard (optional can do direct wiring)

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### Physical Wiring
MAX3010 3.3v -> nucelo 3.3v
MAX3010 GND -> nucelo GND
MAX3010 SCL -> nucelo SCL/D15
MAX3010 SDA -> nucleo SDA/D14
* this project does not make use of the INT or 1.8v ring slots

### Concptual interactions
- MAX30101 sensor communicates raw RED/IR photodiode samples buffered in on-chip
FIFO
- STM32-NUCLEO-F302R8 firmware polls FIFO_WR_PTR vs FIFO_RD_PTR every 20ms
driven by the systick timer, on new data it burst reads 6 bytesm 3 RED, 3 IR
- 18-bit values are printed as text over USART2, UART converted over USB serial
  on host machine 
- python visualizer program parses the UART output RED,IR lines and applies
basic bandpass filter to isolate pulse rhythm, estimates BPM over a 8s rolling
windoe and attempts to smooth BPM display with moving average, result is live
sweeping trace and ~BPM readout in the matplotlib GUI

### Other notes
- I2C1 bus config to 100kz standard mode driven off SYSCLK 64MHz via PLL from
HSI
- MAX30101 driver applied at register level, soft reset applied and then
configured in Sp02 mode to make both RED and IR LEDs active, only IR used for
BPM calculations
- FIFO configured with rollover so host latency doesnt stall sensor writes
- Systick driven counter checks every 20ms at ~50Hz sample rate, reads FIFO
pointers and when data pending burst reads one sample to print over UART 
- UART primarily used as debug + data pipeline to enable testing and visualizer
  of raw sample data 
- BPM estimation uses autocorrelation to find the average over many beats hoping
  to be more accurate and resistant to single noisy samples which compromise
peak to peak timing. It works moderately well when maintaining stable, constant
pressure figertip connection but is super sensitive to movements or pressure
changes, thus the limitations of a breadboard setup with no enclosure or
dedicated powersource + honestly poorly soldered connections on the SDA/SCL
slots 

### Toolchain
- Zig 0.17.0-dev nightly
- STM32CubeProgrammer (flashing)
- PuTTY (serial monitor)
