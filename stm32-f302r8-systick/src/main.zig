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

// SysTick is slot 15 in the Cortex-M spec (idx 13 here after reset hanler as first)
// sysTickHandler replaces default here to handle the interrupt
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

// LD2
const GPIOB_BASE: u32 = 0x48000400;
const GPIOB_MODER: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x00);
const GPIOB_BSRR: *volatile u32 = @ptrFromInt(GPIOB_BASE + 0x18);

const PIN_13_SHIFT: u5 = 26; // Pin 13 * 2 (for MODER/PUPDR)

// SysTick (Cortex-M core peripheral, fixed address)
const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000E010); // control and status
const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000E014); // reload value
const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000E018); // current value

var ticks: u32 = 0; // written by the interrupt handler, read by main
const ticks_ptr: *volatile u32 = &ticks; // must be volatile to not be optimized away

// ============================================================================
// 3. MAIN LOGIC (LED Toggle)
// ============================================================================
pub fn main() void {
    // Enable clocks for AHB
    //  GPIOB (bit 18)
    RCC_AHBENR.* |= (1 << 18);

    // SysTick: interrupt every 1ms
    // interval = RVR / clock_speed
    // 8MHz / 8000 = 1000 ticks per second
    SYST_RVR.* = 8_000 - 1; // reload value (counts down to 0)
    SYST_CVR.* = 0; // clear current value
    SYST_CSR.* = 0b111; // enable counter, enable interrupt, use processor clock

    // Configure PB13 (LED) as Output (MODER bits [27:26] = 0b01)
    GPIOB_MODER.* &= ~(@as(u32, 0b11) << PIN_13_SHIFT);
    GPIOB_MODER.* |= (@as(u32, 0b01) << PIN_13_SHIFT);

    var led_on: bool = false;
    var last_tick: u32 = 0;

    while (true) {
        // Toggle every 1000ms (1000 ticks), CPU free in meantime, no spin delay and burnt cycles
        // ticks - last_tick works due to integer overflow wrapping
        if (ticks_ptr.* - last_tick >= 1_000) {
            last_tick = ticks_ptr.*; // update
            led_on = !led_on; // toggle

            // Set based on new toggled state
            if (led_on) {
                GPIOB_BSRR.* = (1 << 13); // LED ON
            } else {
                GPIOB_BSRR.* = (1 << 29); // LED OFF
            }
        }
    }
}

/// SysTick interrupt handler
/// Things that are acceptable in a handler
/// 1. increment a counter
/// 2. set a boolean flag
/// 3. write to a register to toggle GPIO
fn sysTickHandler() callconv(.c) void {
    ticks_ptr.* += 1;
}
