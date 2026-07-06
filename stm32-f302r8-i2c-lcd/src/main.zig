// STM32F302R8 bare metal

// ============================================================================
// 1. LINKER SYMBOLS & STARTUP (Previously startup.zig)
// ============================================================================
extern var _sidata: u32; // start of .data in FLASH (load address)
extern var _sdata: u32; // start of .data in RAM
extern var _edata: u32; // end of .data in RAM
extern var _sbss: u32; // start of .bss (zero initialized memory)
extern var _ebss: u32; // end of .bss
extern var _estack: u32; // top of stack pointer, defined in linker script

const VectorTable = extern struct {
    initial_sp: *u32,
    reset: *const fn () callconv(.c) noreturn,
    exceptions: [14]*const fn () callconv(.c) void,
};

fn defaultHandler() callconv(.c) void {
    while (true) {}
}

export const vector_table linksection(".isr_vector") = VectorTable{
    .initial_sp = &_estack,
    .reset = Reset_Handler,
    .exceptions = .{
        defaultHandler, // NMI
        defaultHandler, // HardFault
        defaultHandler, // MemManage
        defaultHandler, // BusFault
        defaultHandler, // UsageFault
        defaultHandler, // reserved
        defaultHandler, // reserved
        defaultHandler, // reserved
        defaultHandler, // reserved
        defaultHandler, // SVCall
        defaultHandler, // DebugMon
        defaultHandler, // reserved
        defaultHandler, // PendSV
        sysTickHandler, // SysTick
    },
};

export fn Reset_Handler() noreturn {
    // Copy .data from FLASH to RAM
    const data_src = @as([*]u32, @ptrCast(&_sidata));
    const data_dst = @as([*]u32, @ptrCast(&_sdata));
    const data_len = (@intFromPtr(&_edata) - @intFromPtr(&_sdata)) / 4;
    for (0..data_len) |i| {
        data_dst[i] = data_src[i];
    }

    // Zero .bss
    const bss_dst = @as([*]u32, @ptrCast(&_sbss));
    const bss_len = (@intFromPtr(&_ebss) - @intFromPtr(&_sbss)) / 4;
    for (0..bss_len) |i| {
        bss_dst[i] = 0;
    }

    // Jump to our main logic
    main();

    // Catch-all if main ever returns
    while (true) {}
}

// ============================================================================
// 2. HARDWARE REGISTERS
// ============================================================================
const RCC_BASE: u32 = 0x40021000;
const RCC_AHBENR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x14); // clocks
const RCC_APB1ENR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x1C); // usart2
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x18); // ADC1
const RCC_CR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x00); // clock control
const RCC_CFGR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x04); // clock config
const RCC_CFGR3: *volatile u32 = @ptrFromInt(RCC_BASE + 0x30);

// GPIOA for PA2 USART2 TX
const GPIOA_BASE: u32 = 0x48000000;
const GPIOA_MODER: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x00);
const GPIOA_AFRL: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x20); // alternate function register low

// USART2
const USART2_BASE: u32 = 0x40004400;
const USART2_BRR: *volatile u32 = @ptrFromInt(USART2_BASE + 0x0C); // baud rate register
const USART2_CR1: *volatile u32 = @ptrFromInt(USART2_BASE + 0x00); // control register 1
const USART2_ISR: *volatile u32 = @ptrFromInt(USART2_BASE + 0x1C); // interrupt status register
const USART2_TDR: *volatile u8 = @ptrFromInt(USART2_BASE + 0x28); // transmit data register, writes one byte at a time

const PIN_2_SHIFT: u3 = 4; // Pin 2 * 2

// SysTick (Cortex-M core peripheral, fixed address)
const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000E010); // control and status
const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000E014); // reload value
const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000E018); // current value

// Flash latency register
const FLASH_BASE: u32 = 0x40022000;
const FLASH_ACR: *volatile u32 = @ptrFromInt(FLASH_BASE + 0x00);

// NVIC
const NVIC_ISER0: *volatile u32 = @ptrFromInt(0xE000E100);

// GPIOB for PB8 (SCL) and PB9 (SDA)
const GPIOB_BASE: u32 = 0x48000400;
const GPIOB_MODER:   *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x00);
const GPIOB_OTYPER:  *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x04);
const GPIOB_OSPEEDR: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x08);
const GPIOB_PUPDR:   *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x0C);
const GPIOB_AFRH: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x24);

// I2C1
const I2C1_BASE: u32 = 0x40005400;
const I2C1_CR1:    *volatile u32 = @ptrFromInt(I2C1_BASE + 0x00);
const I2C1_CR2:    *volatile u32 = @ptrFromInt(I2C1_BASE + 0x04);
const I2C1_TIMINGR:*volatile u32 = @ptrFromInt(I2C1_BASE + 0x10);
const I2C1_ISR:    *volatile u32 = @ptrFromInt(I2C1_BASE + 0x18);
const I2C1_ICR:    *volatile u32 = @ptrFromInt(I2C1_BASE + 0x1C);
const I2C1_RXDR:   *volatile u8  = @ptrFromInt(I2C1_BASE + 0x24);
const I2C1_TXDR:   *volatile u8  = @ptrFromInt(I2C1_BASE + 0x28);

// ============================================================================
// 3. SHARED STATE
// ============================================================================
var ticks: u32 = 0;
const ticks_ptr: *volatile u32 = &ticks;

// ============================================================================
// 4. MAIN LOGIC
// ============================================================================
pub fn main() void {
    // Flash latency before increasing clock speed
    FLASH_ACR.* |= (0b010 << 0);

    // PLL config: HSI/2 * 16 = 64MHz
    RCC_CFGR.* &= ~(@as(u32, 0b111111) << 16);
    RCC_CFGR.* |= (@as(u32, 0b1110) << 18); // PLLMUL = x16
    RCC_CFGR.* &= ~(@as(u32, 0b11111111111) << 4);
    RCC_CFGR.* |= (@as(u32, 0b100) << 8); // APB1 = /2
    RCC_CR.* |= (1 << 24); // enable PLL
    while ((RCC_CR.* & (1 << 25)) == 0) {}
    RCC_CFGR.* &= ~(@as(u32, 0b11) << 0);
    RCC_CFGR.* |= (@as(u32, 0b10) << 0); // switch to PLL
    while ((RCC_CFGR.* & (@as(u32, 0b11) << 2)) != (@as(u32, 0b10) << 2)) {}

    // Enable all clocks
    RCC_AHBENR.* |= (1 << 17); // GPIOA
    RCC_APB1ENR.* |= (1 << 17); // USART2
    RCC_APB1ENR.* |= (1 << 28); // PWR
    RCC_APB2ENR.* |= (1 << 0); // SYSCFG

    // GPIO and USART2
    GPIOA_MODER.* &= ~(@as(u32, 0b11) << PIN_2_SHIFT);
    GPIOA_MODER.* |= (@as(u32, 0b10) << PIN_2_SHIFT); // PA2 AF mode
    GPIOA_MODER.* |= (@as(u32, 0b11) << 0); // PA0 analog
    GPIOA_AFRL.* &= ~(@as(u32, 0xF) << 8);
    GPIOA_AFRL.* |= (@as(u32, 0x7) << 8); // PA2 AF7
    USART2_BRR.* = 277; // 32_000_000 / 115200 = 277
    USART2_CR1.* |= (1 << 0) | (1 << 3);
    uartPrint("UART OK\r\n");

    // I2C init
    i2cInit();
    uartPrint("I2C OK\r\n");
    i2cScan();

    // LED screen init test/message
    lcdInit();
    uartPrint("LCD OK\r\n");

    lcdCmd(0x80); // cursor to row 1, col 0
    lcdPrint("Hello :)");

    lcdCmd(0xC0); // cursor to row 2, col 0
    lcdPrint("I2C LCD works!");

    // SysTick
    SYST_RVR.* = 64_000 - 1; // 1ms tick at 64MHz
    SYST_CVR.* = 0;
    SYST_CSR.* = 0b111;
    uartPrint("INIT OK\r\n");

    // Main loop 
    var last_tick: u32 = 0;

    //var print_word: bool = true;
    //var print_count: u32 = 0;

    // Expected pattern 
    // Clear 
    // Print top 
    // CLear 
    // Print bottom
    // while (true) {
    //     // Toggle every 3000ms (3000 ticks), CPU free in meantime, no spin delay and burnt cycles
    //     // ticks - last_tick works due to integer overflow wrapping
    //     if (ticks_ptr.* - last_tick >= 3_000) {
    //         last_tick = ticks_ptr.*; // update
    //         print_word = !print_word; // toggle
    //
    //         // Set based on new toggled state
    //         if (print_word) {
    //             if(print_count % 2 == 0) {
    //                 // Top row
    //                 lcdCmd(0x80);
    //                 lcdPrint("Top");
    //             } else {
    //                 // Bottom row
    //                 lcdCmd(0xC0);   // 0x80 + 64 = 0xC0
    //                 lcdPrint("Bottom");
    //             }
    //             print_count += 1;
    //         } else {
    //             // Clear 
    //             lcdCmd(CLEAR);
    //         }
    //     }
    // }
    
    // Expected pattern 
    // Moving moves accross top and bottom row
    // Naieve clear and draw, could just shift 
    var pos: u8 = 0;
    while (true) {
        if (ticks_ptr.* - last_tick >= 500) {
            last_tick = ticks_ptr.*; // update
            lcdCmd(CLEAR);
            const cursor_pos: u8 = 128 + pos;
            lcdCmd(cursor_pos);
            pos += 1;
            if(pos == 15) pos = 64;
            if(pos == 79) pos = 0;
            lcdPrint("Moving");
        }
    }
}

// ============================================================================
// 5. HELPERS / HANDLERS
// ============================================================================

// HD44780 Instruction Set 
const CLEAR: u8 = 0x01;
const CUR_HOME: u8 = 0x02; // unshift display
const DISP_OFF: u8 = 0x08;
const BLINK_CURS: u8 = 0x0F;
const CUR_LEFT: u8 = 0x10;
const CUR_RIGHT: u8 = 0x14;
const DISP_LEFT: u8 = 0x18;
const DISP_RIGHT: u8 = 0x1c;

// CURSOR POSITION = 0x80 + pos decimal 
// 16 x 2 display 
// Line 1 = pos 0-15
// Line 2 = pos 64-79 as HD44780 designed for 40 character 4 line display

/// SysTick interrupt handler
fn sysTickHandler() callconv(.c) void {
    ticks_ptr.* += 1;
}

/// Send single byte over UART2
fn uartSendByte(byte: u8) void {
    // Wait until TXE (bit 7) is set
    while ((USART2_ISR.* & (1 << 7)) == 0) {}
    USART2_TDR.* = byte;
}

/// UART can't send u32 only raw u8 bytes
/// Even raw u8 bytes wont be visible in output as u8 0 is not ASCII printable 0
/// To handle printing, extract each single number in the whole, eg 23 = 2, 3 and convert to ASCII
/// ASCII 0 starts at u8 value 48
fn uartSendU32(n: u32) void {
    if (n == 0) {
        uartSendByte('0');
        return;
    }

    // Build digits in reverse into a small buffer
    var buf: [10]u8 = undefined; // u32 max is 4294967295, 10 digits
    var i: usize = 0;
    var remaining = n;

    while (remaining > 0) {
        buf[i] = @intCast(remaining % 10 + '0'); // '0' is u8 value 48
        remaining /= 10;
        i += 1;
    }

    // Send in reverse (we built it backwards)
    while (i > 0) {
        i -= 1;
        uartSendByte(buf[i]);
    }
}

/// Print a string using single byte writes
fn uartPrint(s: []const u8) void {
    for (s) |byte| {
        uartSendByte(byte);
    }
}

/// Init I2C Coms 
fn i2cInit() void {
    // Enable GPIOB and I2C1 clocks
    RCC_AHBENR.* |= (1 << 18);   // GPIOB
    RCC_APB1ENR.* |= (1 << 21);  // I2C1

    // Switch I2C1 clock to SYSCLK (64MHz) — default is HSI (8MHz)
    RCC_CFGR3.* |= (1 << 4);

    // PB8 = SCL, PB9 = SDA — AF mode
    GPIOB_MODER.* &= ~(@as(u32, 0b1111) << 16);
    GPIOB_MODER.* |=  (@as(u32, 0b1010) << 16);

    // Open-drain
    GPIOB_OTYPER.* |= (1 << 8) | (1 << 9);

    // High speed
    GPIOB_OSPEEDR.* |= (@as(u32, 0b1111) << 16);

    // Pull-up
    GPIOB_PUPDR.* &= ~(@as(u32, 0b1111) << 16);
    GPIOB_PUPDR.* |=  (@as(u32, 0b0101) << 16);

    // AF4 for I2C1 on PB8 (bits 3:0 of AFRH) and PB9 (bits 7:4 of AFRH)
    GPIOB_AFRH.* &= ~(@as(u32, 0xFF) << 0);
    GPIOB_AFRH.* |=  (@as(u32, 0x44) << 0);

    // Disable I2C before setting timing
    I2C1_CR1.* &= ~(@as(u32, 1) << 0);

    // Short delay to let peripheral reset
    var d: u32 = 0;
    while (d < 10_000) : (d += 1) {
        asm volatile ("nop");
    }

    // Timing for 100kHz standard mode at 64MHz I2C clock (SYSCLK)
    I2C1_TIMINGR.* = 0x10420F13;

    // Enable I2C1
    I2C1_CR1.* |= (1 << 0);
}

/// I2C scan connections for debugging
fn i2cScan() void {
    uartPrint("I2C scan:\r\n");
    var addr: u7 = 0x08;
    while (addr < 0x78) : (addr += 1) {
        // Send just a start + address + stop, check for ACK
        I2C1_ICR.* |= (1 << 4);
        I2C1_CR2.* = (@as(u32, addr) << 1) |
                     (@as(u32, 1) << 16) |
                     (1 << 25); // AUTOEND
        I2C1_CR2.* |= (1 << 13); // START

        var timeout: u32 = 10_000;
        var acked = false;
        while (timeout > 0) : (timeout -= 1) {
            const isr = I2C1_ISR.*;
            if ((isr & (1 << 4)) != 0) { // NACK
                I2C1_ICR.* |= (1 << 4);
                break;
            }
            if ((isr & (1 << 1)) != 0) { // TXIS — device acked address
                acked = true;
                // Send dummy byte and let AUTOEND stop it
                I2C1_TXDR.* = 0x00;
                break;
            }
            if ((isr & (1 << 5)) != 0) { // STOPF
                I2C1_ICR.* |= (1 << 5);
                break;
            }
        }

        // Wait for stop
        timeout = 10_000;
        while ((I2C1_ISR.* & (1 << 15)) != 0 and timeout > 0) : (timeout -= 1) {}
        I2C1_ICR.* = 0xFF;

        if (acked) {
            uartPrint("  ACK at 0x");
            uartSendU32(addr);
            uartPrint("\r\n");
        }
    }
    uartPrint("scan done\r\n");
}

/// Write then read: send register address, receive nbytes into buf
/// Returns false on NACK or timeout
fn i2cReadReg(addr: u7, reg: u8, buf: []u8) bool {
    // Check bus not busy
    var timeout: u32 = 100_000;
    while ((I2C1_ISR.* & (1 << 15)) != 0) {
        timeout -= 1;
        if (timeout == 0) {
            uartPrint("I2C BUSY\r\n");
            return false;
        }
    }

    // Clear NACK flag
    I2C1_ICR.* |= (1 << 4);

    // Write phase — send register address, no autoend
    I2C1_CR2.* = (@as(u32, addr) << 1) |
                 (@as(u32, 1) << 16) |
                 (0 << 10);
    I2C1_CR2.* |= (1 << 13); // START

    timeout = 100_000;
    while ((I2C1_ISR.* & (1 << 1)) == 0) {
        if ((I2C1_ISR.* & (1 << 4)) != 0) {
            uartPrint("I2C NACK write\r\n");
            return false;
        }
        timeout -= 1;
        if (timeout == 0) {
            uartPrint("I2C timeout TXIS\r\n");
            return false;
        }
    }
    I2C1_TXDR.* = reg;

    // Wait for TC
    timeout = 100_000;
    while ((I2C1_ISR.* & (1 << 6)) == 0) {
        if ((I2C1_ISR.* & (1 << 4)) != 0) {
            uartPrint("I2C NACK TC\r\n");
            return false;
        }
        timeout -= 1;
        if (timeout == 0) {
            uartPrint("I2C timeout TC\r\n");
            return false;
        }
    }

    // Read phase — repeated start
    I2C1_CR2.* = (@as(u32, addr) << 1) |
                 (@as(u32, buf.len) << 16) |
                 (1 << 10) |   // read
                 (1 << 25);    // AUTOEND
    I2C1_CR2.* |= (1 << 13); // repeated START

    for (buf) |*byte| {
        timeout = 100_000;
        while ((I2C1_ISR.* & (1 << 2)) == 0) {
            if ((I2C1_ISR.* & (1 << 4)) != 0) {
                uartPrint("I2C NACK read\r\n");
                return false;
            }
            timeout -= 1;
            if (timeout == 0) {
                uartPrint("I2C timeout RXNE\r\n");
                return false;
            }
        }
        byte.* = I2C1_RXDR.*;
    }

    // Wait for STOPF
    timeout = 100_000;
    while ((I2C1_ISR.* & (1 << 5)) == 0) {
        timeout -= 1;
        if (timeout == 0) {
            uartPrint("I2C timeout STOP\r\n");
            return false;
        }
    }
    I2C1_ICR.* |= (1 << 5);

    return true;
}


/// Controlling the LED screen over I2C
/// Write a single byte to the PCF8574 over I2C
fn lcdI2cWrite(data: u8) void {
    var buf = [1]u8{data};
    _ = i2cWriteRaw(0x27, &buf);
}

/// Raw I2C write — just send bytes, no register address
fn i2cWriteRaw(addr: u7, buf: []const u8) bool {
    var timeout: u32 = 100_000;
    while ((I2C1_ISR.* & (1 << 15)) != 0) {
        timeout -= 1;
        if (timeout == 0) return false;
    }

    I2C1_ICR.* |= (1 << 4);
    I2C1_CR2.* = (@as(u32, addr) << 1) |
                 (@as(u32, buf.len) << 16) |
                 (1 << 25) |  // AUTOEND
                 (0 << 10);   // write
    I2C1_CR2.* |= (1 << 13); // START

    for (buf) |byte| {
        timeout = 100_000;
        while ((I2C1_ISR.* & (1 << 1)) == 0) {
            if ((I2C1_ISR.* & (1 << 4)) != 0) return false;
            timeout -= 1;
            if (timeout == 0) return false;
        }
        I2C1_TXDR.* = byte;
    }

    timeout = 100_000;
    while ((I2C1_ISR.* & (1 << 5)) == 0) {
        timeout -= 1;
        if (timeout == 0) return false;
    }
    I2C1_ICR.* |= (1 << 5);
    return true;
}

/// Pulse the enable bit to latch a nibble into the HD44780
fn lcdPulseEnable(data: u8) void {
    // Backlight bit = bit 3 (0x08), Enable bit = bit 2 (0x04)
    lcdI2cWrite(data | 0x04 | 0x08); // EN high + backlight
    delay_us(1);
    lcdI2cWrite((data & ~@as(u8, 0x04)) | 0x08); // EN low + backlight
    delay_us(50);
}

/// Send a nibble (upper 4 bits of data used)
fn lcdSendNibble(nibble: u8, rs: u8) void {
    // bits 7:4 = data, bit 3 = backlight, bit 2 = EN, bit 1 = RW, bit 0 = RS
    const data: u8 = (nibble & 0xF0) | 0x08 | rs; // backlight on, RS as given
    lcdPulseEnable(data);
}

/// Send a full byte as two nibbles
fn lcdSendByte(byte: u8, rs: u8) void {
    lcdSendNibble(byte & 0xF0, rs);           // high nibble
    lcdSendNibble((byte << 4) & 0xF0, rs);   // low nibble
}

/// Send a command (RS=0)
fn lcdCmd(cmd: u8) void {
    lcdSendByte(cmd, 0x00);
    delay_us(200);
}

/// Send a data character (RS=1)
fn lcdChar(c: u8) void {
    lcdSendByte(c, 0x01);
    delay_us(50);
}

/// Print a string to the LCD
fn lcdPrint(s: []const u8) void {
    for (s) |c| {
        lcdChar(c);
    }
}


/// Microsecond delay using nop loops at 64MHz
/// Roughly 64 nops = 1us
fn delay_us(us: u32) void {
    var i: u32 = 0;
    while (i < us * 64) : (i += 1) {
        asm volatile ("nop");
    }
}

fn delay_ms(ms: u32) void {
    delay_us(ms * 1000);
}

/// Initialise the HD44780 in 4-bit mode via PCF8574
fn lcdInit() void {
    // Wait for LCD power on — HD44780 needs >40ms after Vcc rises
    delay_ms(50);

    // Initial state — backlight on, everything else low
    lcdI2cWrite(0x08);
    delay_ms(10);

    // Wake up sequence — send 0x30 three times in 4-bit mode init
    lcdSendNibble(0x30, 0x00);
    delay_ms(5);
    lcdSendNibble(0x30, 0x00);
    delay_us(200);
    lcdSendNibble(0x30, 0x00);
    delay_us(200);

    // Switch to 4-bit mode
    lcdSendNibble(0x20, 0x00);
    delay_us(200);

    // Now in 4-bit mode — configure display
    lcdCmd(0x28); // 4-bit, 2 lines, 5x8 font
    lcdCmd(0x0C); // display on, cursor off, blink off
    lcdCmd(0x06); // entry mode: increment, no shift
    lcdCmd(0x01); // clear display
    delay_ms(2);  // clear needs >1.5ms
}
