// STM32F302R8 bare metal
// LED:    LD2 on PB13
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
};

fn defaultHandler() callconv(.c) void {
    while (true) {}
}

export const vector_table linksection(".isr_vector") = VectorTable{
    .initial_sp = &_estack,
    .reset = Reset_Handler,
    .exceptions = .{defaultHandler} ** 14,
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

// PA2 for USART2 TX
const GPIOA_BASE: u32 = 0x48000000;
const GPIOA_MODER: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x00);
const GPIOA_AFRL: *volatile u32 = @ptrFromInt(GPIOA_BASE + 0x20); // alternate function register low

// LD2
const GPIOB_BASE: u32 = 0x48000400;
const GPIOB_MODER: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x00);
const GPIOB_BSRR: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x18);

// Blue B1 USER button
const GPIOC_BASE: u32 = 0x48000800;
const GPIOC_MODER: *volatile u32 = @ptrFromInt(GPIOC_BASE + 0x00);
const GPIOC_PUPDR: *volatile u32 = @ptrFromInt(GPIOC_BASE + 0x0C);
const GPIOC_IDR: *volatile u32 = @ptrFromInt(GPIOC_BASE + 0x10);

// USART2
const USART2_BASE: u32 = 0x40004400;
const USART2_BRR: *volatile u32 = @ptrFromInt(USART2_BASE + 0x0C); // baud rate register
const USART2_CR1: *volatile u32 = @ptrFromInt(USART2_BASE + 0x00); // control register 1
const USART2_ISR: *volatile u32 = @ptrFromInt(USART2_BASE + 0x1C); // interrupt status register
const USART2_TDR: *volatile u8 = @ptrFromInt(USART2_BASE + 0x28); // transmit data register, writes one byte at a time

const PIN_2_SHIFT: u3 = 4; // Pin 2 * 2
const PIN_13_SHIFT: u5 = 26; // Pin 13 * 2 (for MODER/PUPDR)

// ============================================================================
// 3. MAIN LOGIC (Button / LED Toggle)
// ============================================================================
pub fn main() void {
    // Enable clocks for AHB
    //  GPIOA (bit 17)
    //  GPIOB (bit 18)
    //  GPIOC (bit 19)
    RCC_AHBENR.* |= (1 << 17) | (1 << 18) | (1 << 19);

    // Enable clock for USART2 on APB1
    RCC_APB1ENR.* |= (1 << 17);

    // Configure PA2 to alternate function mode, clear (MODER bits [5:4]) by setting to 0b10
    GPIOA_MODER.* &= ~(@as(u32, 0b11) << PIN_2_SHIFT);
    GPIOA_MODER.* |= (@as(u32, 0b10) << PIN_2_SHIFT);

    // Set AF7 for PA2 in AFRL (bits [11:8])
    GPIOA_AFRL.* &= ~(@as(u32, 0xF) << 8); // clear 4 bits
    GPIOA_AFRL.* |= (@as(u32, 0x7) << 8); // set val to 7 (0b0111)

    // Configure PB13 (LED) as Output (MODER bits [27:26] = 0b01)
    GPIOB_MODER.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT);
    GPIOB_MODER.* |= (@as(u32, 0b01) << PIN_13_SHIFT);

    // Configure PC13 (Button) as Input (MODER bits [27:26] = 0b00) with Pull-up
    GPIOC_MODER.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT); // Input mode
    GPIOC_PUPDR.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT); // Clear pull config
    GPIOC_PUPDR.* |= (@as(u32, 0b01) << PIN_13_SHIFT); // Set to pull-up

    // Set baud rate
    USART2_BRR.* = 69; // set baude rate

    // Set control register, bit 0 (UE) = enable, bit 3 (TE) = transmitter enable
    USART2_CR1.* |= (1 << 0);
    USART2_CR1.* |= (1 << 3);

    var armed: bool = false;
    var last_button: u1 = 1; // Pulled high by default

    while (true) {
        // Read PC13
        const current_button: u1 = if ((GPIOC_IDR.* & (1 << 13)) != 0) 1 else 0;

        // Detect falling edge (button press)
        if (last_button == 1 and current_button == 0) {
            armed = !armed;

            if (armed) {
                GPIOB_BSRR.* = (1 << 13); // Set PB13 (LED ON)
                uartPrint("ON\r\n");
            } else {
                GPIOB_BSRR.* = (1 << 29); // Reset PB13 (LED OFF) - Bit 13 + 16
                uartPrint("OFF\r\n");
            }

            delay(200_000); // Debounce
        }

        last_button = current_button;
        delay(80_000); // Polling interval
    }
}

/// Ensure the compiler doesn't aggressively optimize away the empty loop
fn delay(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

/// Send single byte over UART2
fn uartSendByte(byte: u8) void {
    // Wait until TXE (bit 7) is set
    while ((USART2_ISR.* & (1 << 7)) == 0) {}
    USART2_TDR.* = byte;
}

/// Print a string using single byte writes
fn uartPrint(s: []const u8) void {
    for (s) |byte| {
        uartSendByte(byte);
    }
}
