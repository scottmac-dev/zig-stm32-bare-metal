## MAX4466 breakout mic amp — analog to digital converter (ADC)
Bare metal ADC sampling of an electret microphone via the MAX4466 amplifier
breakout. 
ADC1 runs in continuous mode feeding DMA1 in circular mode into a
256-sample ping-pong buffer. 
The CPU is not involved in data movement — it only
wakes when a buffer half is ready, formats the samples as ASCII integers and
transmits over USART2. 
A Python visualiser plots the incoming stream as a live
audio waveform. 

### Hardware
- Board: STM32-NUCLEO-F302R8
- UART: PA2 TX → ST-LINK virtual COM port
- Adafruit MAX4466 microphone amplifier breakout board
- Breadboard 
- 3 x double ended male jumper cables

### Physical Wiring
- MAX4466 VCC → Nucleo 3.3V
- MAX4466 GND → Nucleo GND
- MAX4466 OUT → PA0 (A0 on Arduino header)

NOTE: Solder header pins to the MAX4466 breakout board before connecting to the
breadboard. A resting connection works but any movement will displace the pins
and introduce significant noise into the signal. 

### Conceptual interactions 
- ADC1 continuously samples PA0 at ~26kHz (601.5 cycle sample time, 64MHz AHB clock)
- DMA1 Channel 1 moves each 16-bit sample from ADC1_DR to adc_buf[] with no CPU involvement
- DMA fires half-transfer interrupt at sample 128, full-transfer interrupt at sample 256
- Handler sets process_buf_offset to 0 or 128 (ping-pong) and raises data_ready flag
- Main loop sees flag, sends 128 samples over USART2 as ASCII integers at 38400 baud
- Python visualiser reads serial stream and plots a rolling 500-sample waveform
- Resting signal sits at ~2048 (VCC/2 midpoint of 12-bit range 0–4095)

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### UART Monitor
Run `visualiser/nucleo-f302r8-audio-waveform.py` to plot a live audio waveform.
The script reads raw ADC integer values from the ST-LINK virtual COM port and
plots a rolling 500-sample window. Update the `PORT` variable in the script to
match your COM port (check Device Manager under Ports).

NOTE: The visualiser requires Windows — WSL2 cannot access COM ports directly.
As an alternative, open PuTTY in serial mode on your COM port at 38400 baud to
see the raw ADC sample stream.

### Toolchain
- Zig 0.16.0-dev nightly
- STM32CubeProgrammer (flashing)
- Python to run visualiser
- PuTTY (serial monitor)
