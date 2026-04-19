// STM32F302R8 bare metal
// UART:   USART2 on PA2 (TX) / PA3 (RX) @ 115200, 8N1, HSI 8MHz

// ============================================================================
// 1. LINKER SYMBOLS & STARTUP (Previously startup.zig)
// ============================================================================
extern var _sidata: u32; // start of .data in FLASH (load address)
extern var _sdata: u32; // start of .data in RAM
extern var _edata: u32; // end of .data in RAM
extern var _sbss: u32; // start of .bss (zero initialized memory)
extern var _ebss: u32; // end of .bss
extern var _estack: u32; // top of stack pointer, defined in linker script

// Minimum vector table needed just to boot and handle a fault.
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
        sysTickHandler, // SysTick ← slot 14, index 13
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
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x18); // TIM1 clock

// GPIOA
const GPIOA_BASE: u32 = 0x48000000;
const GPIOA_MODER: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x00);
const GPIOA_AFRL: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x20); // alternate function register low
const GPIOA_AFRH: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x24); // AF register high PA8-PA15

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

// TIM1 registers
const TIM1_BASE: u32 = 0x40012C00;
const TIM1_CR1: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x00); // CR1 control register
const TIM1_PSC: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x28); // PSC prescaler
const TIM1_ARR: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x2C); // ARR auto reload register
const TIM1_CCR1: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x34); // capture compare channel 1
const TIM1_CCMR1: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x18); // capture compare mode register
const TIM1_CCER: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x20); // capture compare enable register
const TIM1_BDTR: *volatile u32 = @ptrFromInt(TIM1_BASE + 0x44); // break and dead-time register

// FLAGS: volatile global shared state
var ticks: u32 = 0; // written by the interrupt handler, read by main
const ticks_ptr: *volatile u32 = &ticks; // must be volatile to not be optimized away

// ============================================================================
// 3. MAIN LOGIC (Servo motor sweep)
// ============================================================================
pub fn main() void {
    // Enable clocks for AHB
    //  GPIOA (bit 17)
    RCC_AHBENR.* |= (1 << 17);

    // Enable clock for USART2 on APB1
    RCC_APB1ENR.* |= (1 << 17);

    // Enable TIM1 clock (advanced timer) on APB2 bit 11
    RCC_APB2ENR.* |= (1 << 11);

    // SysTick: interrupt every 1ms
    // interval = RVR / clock_speed
    // 8MHz / 8000 = 1000 ticks per second
    SYST_RVR.* = 8_000 - 1; // reload value (counts down to 0)
    SYST_CVR.* = 0; // clear current value
    SYST_CSR.* = 0b111; // enable counter, enable interrupt, use processor clock

    // Configure PA2 to alternate function mode, clear (MODER bits [5:4]) by setting to 0b10
    GPIOA_MODER.* &= ~(@as(u32, 0b11) << PIN_2_SHIFT);
    GPIOA_MODER.* |= (@as(u32, 0b10) << PIN_2_SHIFT);

    // Set AF7 for PA2 in AFRL (bits [11:8])
    GPIOA_AFRL.* &= ~(@as(u32, 0xF) << 8); // clear 4 bits
    GPIOA_AFRL.* |= (@as(u32, 0x7) << 8); // set val to 7 (0b0111)

    // PA8 → alternate function mode (MODER bits [17:16] = 0b10)
    GPIOA_MODER.* &= ~(@as(u32, 0b11) << 16);
    GPIOA_MODER.* |= (@as(u32, 0b10) << 16);

    // Set AF6 for PA8 in AFRH (bits [3:0])
    GPIOA_AFRH.* &= ~(@as(u32, 0xF) << 0);
    GPIOA_AFRH.* |= (@as(u32, 0x6) << 0);

    // Set baud rate
    USART2_BRR.* = 69; // set baude rate

    // Set control register, bit 0 (UE) = enable, bit 3 (TE) = transmitter enable
    USART2_CR1.* |= (1 << 0);
    USART2_CR1.* |= (1 << 3);

    // TIM1 & PWM config
    TIM1_PSC.* = 7; // 8MHz / 8 = 1MHz, prescales down to 1MHz
    TIM1_ARR.* = 19_999; // 20ms period
    TIM1_CCR1.* = 1_500; // 1.5ms = centre position

    // CCMR1: channel 1 in PWM mode 1 (OC1M = 0b110, bits [6:4]), output high while counter < CCR1
    TIM1_CCMR1.* |= (0b110 << 4);
    // Preload enable for CCR1 (bit 3) — updates take effect at next period
    TIM1_CCMR1.* |= (1 << 3);

    // Enable channel output
    TIM1_CCER.* |= (1 << 0); // CC1E — enable channel 1 output
    TIM1_BDTR.* |= (1 << 15); // MOE — main output enable (required for TIM1)
    TIM1_CR1.* |= (1 << 0); // CEN — enable the count

    var last_tick: u32 = 0;
    var pulse: u32 = 1_500; // start at centre
    var direction: i32 = 1; // 1 = moving toward 2000, -1 = moving toward 1000

    // Init message
    uartPrint("PWM servo sweep starting...\r\n");
    uartPrint("Range: 500us - 2500us\r\n");

    // MAIN loop
    // Sweep the servo so it moves from 0 -> 180 and back
    // Steps pulse width by 10 microseconds every 20ms = 100 steps for full range = ~2 second sweep
    while (true) {
        // Move every 20ms
        if (ticks_ptr.* - last_tick >= 20) {
            last_tick = ticks_ptr.*;

            // Step pulse width by 10us each update
            pulse = @intCast(@as(i32, @intCast(pulse)) + (direction * 10));

            // Reverse direction at limits
            if (pulse >= 2_500) {
                pulse = 2_500;
                direction = -1;
            } else if (pulse <= 500) {
                pulse = 500;
                direction = 1;
            }

            // Update CCR1 — takes effect at next period
            TIM1_CCR1.* = pulse;

            // Print current pulse width for debugging
            uartPrint("PULSE: ");
            uartSendU32(pulse);
            uartPrint("us\r\n");
        }
    }
}

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
