// STM32F302R8 bare metal
// MAX4466 mic on PA0 → ADC1 → DMA1 CH1 → ping-pong buffer → USART2

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
    irqs: [12]*const fn () callconv(.c) void, // IRQ0..IRQ11 (DMA1_CH1 = IRQ11)
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
    .irqs = .{defaultHandler} ** 11 ++ .{dma1Channel1Handler},
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

// ADC1
const ADC1_BASE: u32 = 0x50000000;
const ADC1_ISR: *volatile u32 = @ptrFromInt(ADC1_BASE + 0x000);
const ADC1_CR: *volatile u32 = @ptrFromInt(ADC1_BASE + 0x008);
const ADC1_CFGR: *volatile u32 = @ptrFromInt(ADC1_BASE + 0x00C);
const ADC1_SMPR1: *volatile u32 = @ptrFromInt(ADC1_BASE + 0x014);
const ADC1_SQR1: *volatile u32 = @ptrFromInt(ADC1_BASE + 0x030);
const ADC1_DR: *volatile u16 = @ptrFromInt(ADC1_BASE + 0x040);
const ADC_CCR: *volatile u32 = @ptrFromInt(0x50000300 + 0x008);

// DMA1 Channel 1
const DMA1_BASE: u32 = 0x40020000;
const DMA1_ISR: *volatile u32 = @ptrFromInt(DMA1_BASE + 0x00);
const DMA1_IFCR: *volatile u32 = @ptrFromInt(DMA1_BASE + 0x04);
const DMA1_CCR1: *volatile u32 = @ptrFromInt(DMA1_BASE + 0x08);
const DMA1_CNDTR1: *volatile u32 = @ptrFromInt(DMA1_BASE + 0x0C);
const DMA1_CPAR1: *volatile u32 = @ptrFromInt(DMA1_BASE + 0x10);
const DMA1_CMAR1: *volatile u32 = @ptrFromInt(DMA1_BASE + 0x14);

// NVIC
const NVIC_ISER0: *volatile u32 = @ptrFromInt(0xE000E100);

// ============================================================================
// 3. SHARED STATE
// ============================================================================
const ADC_BUF_SIZE: usize = 256;
var adc_buf: [ADC_BUF_SIZE]u16 = undefined;

var ticks: u32 = 0;
const ticks_ptr: *volatile u32 = &ticks;

var data_ready: bool = false;
const data_ready_ptr: *volatile bool = &data_ready;

var process_buf_offset: usize = 0;
const process_buf_offset_ptr: *volatile usize = &process_buf_offset;

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
    RCC_AHBENR.* |= (1 << 0); // DMA1
    RCC_AHBENR.* |= (1 << 17); // GPIOA
    RCC_AHBENR.* |= (1 << 28); // ADC1
    RCC_APB1ENR.* |= (1 << 17); // USART2
    RCC_APB1ENR.* |= (1 << 28); // PWR
    RCC_APB2ENR.* |= (1 << 0); // SYSCFG

    // GPIO and USART2
    GPIOA_MODER.* &= ~(@as(u32, 0b11) << PIN_2_SHIFT);
    GPIOA_MODER.* |= (@as(u32, 0b10) << PIN_2_SHIFT); // PA2 AF mode
    GPIOA_MODER.* |= (@as(u32, 0b11) << 0); // PA0 analog
    GPIOA_AFRL.* &= ~(@as(u32, 0xF) << 8);
    GPIOA_AFRL.* |= (@as(u32, 0x7) << 8); // PA2 AF7
    USART2_BRR.* = 833;
    USART2_CR1.* |= (1 << 0) | (1 << 3);
    uartPrint("UART OK\r\n");

    // ADC clock — synchronous AHB/1
    ADC_CCR.* &= ~(@as(u32, 0b11) << 16);
    ADC_CCR.* |= (@as(u32, 0b01) << 16);
    uartPrint("ADC CLK OK\r\n");

    // Exit deep power down, enable voltage regulator
    ADC1_CR.* = 0;
    ADC1_CR.* &= ~(@as(u32, 1) << 29);
    ADC1_CR.* |= (@as(u32, 1) << 28);
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        asm volatile ("nop");
    }
    uartPrint("ADVREGEN OK\r\n");

    // Calibrate single ended
    ADC1_CR.* &= ~(@as(u32, 1) << 30);
    ADC1_CR.* |= (@as(u32, 1) << 31);
    while ((ADC1_CR.* & (@as(u32, 1) << 31)) != 0) {}
    uartPrint("CAL OK\r\n");

    // Wait for CR to settle, clear flags
    while ((ADC1_CR.* & (@as(u32, 0b11) << 30)) != 0) {}
    ADC1_ISR.* = 0xFF;

    // Configure ADC — continuous, DMA circular, 601.5 cycle sample time
    ADC1_CFGR.* = 0;
    ADC1_CFGR.* |= (1 << 13); // CONT
    ADC1_CFGR.* |= (1 << 1); // DMACFG circular
    ADC1_SMPR1.* = (0b111 << 3);
    ADC1_SQR1.* = (1 << 6);

    // Small gap then enable ADC
    var j: u32 = 0;
    while (j < 1_000) : (j += 1) {
        asm volatile ("nop");
    }
    ADC1_CR.* |= (@as(u32, 1) << 0); // ADEN
    while ((ADC1_ISR.* & (@as(u32, 1) << 0)) == 0) {}
    uartPrint("ADC OK\r\n");

    // Enable DMAEN now that ADC is ready
    ADC1_CFGR.* |= (1 << 0);

    // DMA1 Channel 1: ADC1_DR → adc_buf, halfword, circular
    DMA1_CCR1.* = 0;
    DMA1_CPAR1.* = @intFromPtr(ADC1_DR); // source: ADC data register
    DMA1_CMAR1.* = @intFromPtr(&adc_buf[0]); // dest: buffer
    DMA1_CNDTR1.* = ADC_BUF_SIZE; // 256 halfword transfers
    DMA1_CCR1.* |= (0b01 << 10); // MSIZE = 16 bit
    DMA1_CCR1.* |= (0b01 << 8); // PSIZE = 16 bit
    DMA1_CCR1.* |= (1 << 7); // MINC — increment memory
    DMA1_CCR1.* |= (1 << 5); // CIRC — circular
    DMA1_CCR1.* |= (1 << 3); // HTIE — half transfer interrupt
    DMA1_CCR1.* |= (1 << 2); // TCIE — full transfer interrupt
    DMA1_CCR1.* |= (1 << 0); // EN — enable

    // Enable DMA1 Channel 1 IRQ in NVIC (IRQ11)
    NVIC_ISER0.* |= (1 << 11);

    // SysTick
    SYST_RVR.* = 64_000 - 1;
    SYST_CVR.* = 0;
    SYST_CSR.* = 0b111;

    // Start ADC conversions
    ADC1_CR.* |= (@as(u32, 1) << 2); // ADSTART

    uartPrint("INIT OK\r\n");

    // Main loop — send buffer half when ready
    while (true) {
        if (data_ready_ptr.*) {
            data_ready_ptr.* = false;
            const offset = process_buf_offset_ptr.*;
            for (0..ADC_BUF_SIZE / 2) |k| {
                uartSendU32(adc_buf[offset + k]);
                uartSendByte('\n');
            }
        }
    }
}

// ============================================================================
// 5. HELPERS / HANDLERS
// ============================================================================

/// SysTick interrupt handler
fn sysTickHandler() callconv(.c) void {
    ticks_ptr.* += 1;
}

fn dma1Channel1Handler() callconv(.c) void {
    const isr = DMA1_ISR.*;

    if ((isr & (1 << 2)) != 0) {
        // Half transfer — first half ready
        DMA1_IFCR.* = (1 << 2);
        process_buf_offset_ptr.* = 0;
        data_ready_ptr.* = true;
    }

    if ((isr & (1 << 1)) != 0) {
        // Transfer complete — second half ready
        DMA1_IFCR.* = (1 << 1);
        process_buf_offset_ptr.* = ADC_BUF_SIZE / 2;
        data_ready_ptr.* = true;
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
