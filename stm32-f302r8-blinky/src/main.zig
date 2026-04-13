// STM32F302R8 bare metal
// LED:    LD2 on PB13

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

// LD2
const GPIOB_BASE: u32 = 0x48000400;
const GPIOB_MODER: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x00);
const GPIOB_BSRR: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x18);

const PIN_2_SHIFT: u3 = 4; // Pin 2 * 2
const PIN_13_SHIFT: u5 = 26; // Pin 13 * 2 (for MODER/PUPDR)

// ============================================================================
// 3. MAIN LOGIC (LED Toggle)
// ============================================================================
pub fn main() void {
    // Enable clocks for AHB
    //  GPIOB (bit 18)
    RCC_AHBENR.* |= (1 << 18);

    // Configure PB13 (LED) as Output (MODER bits [27:26] = 0b01)
    GPIOB_MODER.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT);
    GPIOB_MODER.* |= (@as(u32, 0b01) << PIN_13_SHIFT);
    var led_on: bool = false;

    while (true) {

        // If off, turn on
        if (!led_on) {
            GPIOB_BSRR.* = (1 << 13); // Set PB13 (LED ON)
            led_on = true;
        } else {
            // Else turn off
            GPIOB_BSRR.* = (1 << 29); // Reset PB13 (LED OFF) - Bit 13 + 16
            led_on = false;
        }

        delay(1_000_000); // Polling interval ~1 sec
    }
}

/// Ensure the compiler doesn't aggressively optimize away the empty loop
fn delay(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}
