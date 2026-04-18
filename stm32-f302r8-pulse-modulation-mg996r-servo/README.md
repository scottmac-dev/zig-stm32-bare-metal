## pulse with modulation mg996r servo motor
Bare metal PWM output on PA8 using TIM1 to sweep an MG996R servo motor across its full range (180 deg). 
Demonstrates timer prescaler and auto-reload configuration, capture compare for pulse width control, and runtime CCR updates for position changes.

### Hardware
- Board: STM32-NUCLEO-F302R8
- UART: PA2 TX → ST-LINK virtual COM port
- 1 x MG996R servo motor (180 degrees)
- 3 x double ended male jumper cables

### MG996R info 
- Servo motor uses PWM signal standard
- Frequency 50Hz = one pulse every 20ms as a fixed window
- ARR sets the 20 ms period 
- CCR sets the pulse width (~1ms - ~2ms)
- Pulse width controls position 
    - ~0.5ms pulse = 0 deg = full left 
    - ~1.5ms pulse = 90 deg = center 
    - 2.5ms pulse = 180 deg = full right
- At 1MHz, 1 tick = 1 microsecond, to this maps to 
    - 500 ticks = 0.5ms = 0 deg = left
    - 1500 ticks = 1.5ms = 90 deg = center 
    - 2500 ticks = 2.5ms = 180 deg = right
- Connections
    - PA8 (D7)  | servo orange/yellow -> nucleo PA8 pin (D7), for PQM1/1 timer channel
    - power 5V  | servo red -> nucelo 5V
    - GND       | servo brown/black -> nucleo GND

### PWM info
- PWM = pulse with modulation, regulates power to a load by switching the
  voltage on and off rapidly.
- PWM on STM32 timers:
    - timer couts up from 0 to a value called ARR (auto-reload-register)
    - when it reaches ARR it resets to 0 and starts again 
    - the time for a full cycle is the PWM period 
    - inside this cycle, CCR (capture compare register) sets the point where the
      output flips.
    - output is high from 0 -> CCR, low from CCR -> ARR 

### Conceptual interactions 
- SysTick fires every 1ms, increments tick counter
- Main loop checks if 20ms elapsed since last update
- Pulse width stepped by 10us in current direction
- TIM1 CCR1 updated — output changes at next period start
- Servo moves to new position
- At 500us or 2500us limit, direction reverses
- Sweep repeats continuously

### Build
```bash
zig build --release=small
```
### Flash
Open STM32CubeProgrammer, connect via ST-LINK, flash `zig-out/bin/firmware.bin` at `0x08000000`.

### Toolchain
- Zig 0.16.0-dev nightly
- STM32CubeProgrammer (flashing)
- PuTTY (serial monitor)
