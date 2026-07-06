## LCD Screen Output Over I2c

### Hardware
- Board: STM32-NUCLEO-F302R8
- Freenove 1602IIC LCD Screen
- Jumper wires + Breadboard (optional can do direct wiring)

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### Physical Wiring
- LCD VDD -> 5V
- LCG GND -> GND
- LCD SDA -> SDA/D14
- LCD SCL -> SCL/D15

### Concptual interactions
STM32 dev board - I2c -> PCF8574 - GPIO Pins -> HD44780 LCD Controller -> Pixels

PCF8574 = chip on the back of the LCD, 8-but remote GPIO port, instead of
writing to a direct register you write to this output register over I2c. Every
bit corresponds to one physical output pin. Eg. 0b00100100 = Low, Low, High, Low, Low High...

HF44780 LCD controller = doesnt understand I2c, communicates over wires via the
I/O expander. Supports 8-bit or 4-bit mode, in 4-bit mode you can send 4 bit
nibbles. Eg `lcdChar('A')` = ASCII A = 0x41 = 0100 0001 -> `lcdByte()` breaks it
into two nibbles, high nibble = 0110----, low nibble = ----0001

Setting the enable pin allows the LCD to read inputs, enable = HIGH

Sending characters becomes, construct 8-but value -> transmit over i2c via two
nibbles -> PC8574 updates 8 output pins -> HD44780 reads the pins -> enable
pulse tells it to read the values -> char on screen
### Toolchain
- Zig 0.17.0-dev nightly
- STM32CubeProgrammer (flashing)
- PuTTY (serial monitor)
