const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .thumb, .os_tag = .freestanding, .abi = .eabihf, .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 } });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const elf = b.addExecutable(.{
        .name = "firmware",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = false,
        }),
    });

    // Bare metal - no stack protector, no red zone
    elf.root_module.stack_protector = false;
    elf.root_module.red_zone = false;

    // Using CubeMX generated linker script for simplicity
    elf.setLinkerScript(b.path("STM32F302R8TX_FLASH.ld"));

    b.installArtifact(elf);

    // Also produce a .bin file ready for STM32CubeProgrammer to flash
    const bin = b.addObjCopy(elf.getEmittedBin(), .{ .format = .bin });
    const install_bin = b.addInstallBinFile(bin.getOutput(), "firmware.bin");
    b.getInstallStep().dependOn(&install_bin.step);
}
