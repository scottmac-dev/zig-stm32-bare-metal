// STM32F302R8 bare metal
// Button: PC13 (active low, pull-up)
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
    irqs: [41]*const fn () callconv(.c) void, // IRQ0..IRQ40
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
    .irqs = .{defaultHandler} ** 40 ++ .{exti15_10Handler},
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
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(RCC_BASE + 0x18); // syscfg

// PA2 for USART2 TX
const GPIOA_BASE: u32 = 0x48000000;
const GPIOA_MODER: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x00);
const GPIOA_AFRL: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x20); // alternate function register low

// Blue B1 USER button
const GPIOC_BASE: u32 = 0x48000800;
const GPIOC_MODER: *volatile u32 = @ptrFromInt(GPIOC_BASE + 0x00);
const GPIOC_PUPDR: *volatile u32 = @ptrFromInt(GPIOC_BASE + 0x0C);

// USART2
const USART2_BASE: u32 = 0x40004400;
const USART2_BRR: *volatile u32 = @ptrFromInt(USART2_BASE + 0x0C); // baud rate register
const USART2_CR1: *volatile u32 = @ptrFromInt(USART2_BASE + 0x00); // control register 1
const USART2_ISR: *volatile u32 = @ptrFromInt(USART2_BASE + 0x1C); // interrupt status register
const USART2_TDR: *volatile u8 = @ptrFromInt(USART2_BASE + 0x28); // transmit data register, writes one byte at a time

const PIN_2_SHIFT: u3 = 4; // Pin 2 * 2
const PIN_13_SHIFT: u5 = 26; // Pin 13 * 2 (for MODER/PUPDR)

// SysTick (Cortex-M core peripheral, fixed address)
const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000E010); // control and status
const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000E014); // reload value
const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000E018); // current value

// SYSCFG has a set of EXTICRx registers mapping GPIO ports to EXTI lines, each register is 4 pins
const SYSCFG_BASE: u32 = 0x40010000;
const SYSCFG_EXTICR4: *volatile u32 = @ptrFromInt(SYSCFG_BASE + 0x14);

// EXTI
const EXTI_BASE: u32 = 0x40010400;
const EXTI_IMR: *volatile u32 = @ptrFromInt(EXTI_BASE + 0x00); // interrupt mask
const EXTI_FTSR: *volatile u32 = @ptrFromInt(EXTI_BASE + 0x0C); // falling trigger selection
// pending register, set when EXTI detects edge, must be cleared to prevent infinite handler loop
// clearing it is done by writing a 1 to the bit (not 0 — this is a write-1-to-clear register) eg EXTI_PR.* = (1 << 13);
const EXTI_PR: *volatile u32 = @ptrFromInt(EXTI_BASE + 0x14);

// NVIC
// IRQ = interrupt request
// ISER = interrupt set enable register
// The CPU NVIC has a ISER register where each bit corresponds to a IRQ number, setting bit enables it
const NVIC_ISER1: *volatile u32 = @ptrFromInt(0xE000E104); // IRQs 32-63

// FLAGS: volatile global shared state
var ticks: u32 = 0; // written by the interrupt handler, read by main
const ticks_ptr: *volatile u32 = &ticks; // must be volatile to not be optimized away

var button_flag: bool = false; // set by interrupt when pressed
const button_pressed: *volatile bool = &button_flag;

var press_tick: u32 = 0; // total tick time since boot
const press_tick_ptr: *volatile u32 = &press_tick;
var last_press_tick: u32 = 0; // for debounce

// ============================================================================
// 3. MAIN LOGIC (Button count w/ interrupt handler)
// ============================================================================
pub fn main() void {
    // Enable clocks for AHB
    //  GPIOA (bit 17)
    //  GPIOC (bit 19)
    RCC_AHBENR.* |= (1 << 17) | (1 << 19);

    // Enable clock for USART2 on APB1
    RCC_APB1ENR.* |= (1 << 17);

    // Enable SYSCFG clock on APB2
    RCC_APB2ENR.* |= (1 << 0);

    // SysTick: interrupt every 1ms
    // interval = RVR / clock_speed
    // 8MHz / 8000 = 1000 ticks per second
    SYST_RVR.* = 8_000 - 1; // reload value (counts down to 0)
    SYST_CVR.* = 0; // clear current value
    SYST_CSR.* = 0b111; // enable counter, enable interrupt, use processor clock

    // Ensures EXTI13 listens to GPIOC port
    SYSCFG_EXTICR4.* &= ~(@as(u32, 0xF) << 4); // clear bits [7:4]
    SYSCFG_EXTICR4.* |= (@as(u32, 0b0010) << 4); // route GPIOC to EXTI13

    // Ensures button PC13 pulled low will fire the EXTI interrupt
    EXTI_FTSR.* |= (1 << 13); // trigger on falling edge for line 13
    EXTI_IMR.* |= (1 << 13); // unmask EXTI line 13

    // ISER1 covers 32-63, IRQ40 falls in ISER1 at bit 8
    NVIC_ISER1.* |= (1 << 8); // enable IRQ40 (EXTI15_10)

    // Configure PA2 to alternate function mode, clear (MODER bits [5:4]) by setting to 0b10
    GPIOA_MODER.* &= ~(@as(u32, 0b11) << PIN_2_SHIFT);
    GPIOA_MODER.* |= (@as(u32, 0b10) << PIN_2_SHIFT);

    // Set AF7 for PA2 in AFRL (bits [11:8])
    GPIOA_AFRL.* &= ~(@as(u32, 0xF) << 8); // clear 4 bits
    GPIOA_AFRL.* |= (@as(u32, 0x7) << 8); // set val to 7 (0b0111)

    // Configure PC13 (Button) as Input (MODER bits [27:26] = 0b00) with Pull-up
    GPIOC_MODER.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT); // Input mode
    GPIOC_PUPDR.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT); // Clear pull config
    GPIOC_PUPDR.* |= (@as(u32, 0b01) << PIN_13_SHIFT); // Set to pull-up

    // Set baud rate
    USART2_BRR.* = 69; // set baude rate

    // Set control register, bit 0 (UE) = enable, bit 3 (TE) = transmitter enable
    USART2_CR1.* |= (1 << 0);
    USART2_CR1.* |= (1 << 3);

    var count: u32 = 0;
    var last_print_tick: u32 = 0;

    // MAIN loop
    while (true) {

        // now handled by interrupt set flag instead of polling for button state
        if (button_pressed.*) {
            button_pressed.* = false; // clear to prevent infinite handler
            count += 1;

            const elapsed = press_tick_ptr.* - last_print_tick;
            last_print_tick = press_tick_ptr.*;

            // Print btn count
            uartPrint("COUNT: ");
            uartSendU32(count);

            // Print elapsed time since last press
            uartPrint(" ELAPSED: ");
            uartSendU32(elapsed);
            uartPrint("ms\r\n");
        }
    }
}

/// SysTick interrupt handler
fn sysTickHandler() callconv(.c) void {
    ticks_ptr.* += 1;
}

fn exti15_10Handler() callconv(.c) void {
    // Check it was line 13 that fired (lines 10-15 share this IRQ)
    if ((EXTI_PR.* & (1 << 13)) != 0) {
        EXTI_PR.* = (1 << 13); // clear pending flag

        // DEBOUNCE: Ignore if less than 100ms since last press
        if (ticks_ptr.* - last_press_tick >= 100) {
            last_press_tick = ticks_ptr.*;
            press_tick_ptr.* = ticks_ptr.*;
            button_pressed.* = true;
        }
    }
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
