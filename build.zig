const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const t = target.result;
    const aws_c_common_dep = b.dependency("aws-c-common", .{});

    const config_h = b.addConfigHeader(.{
        .style = .{
            .cmake = aws_c_common_dep.path("include/aws/common/config.h.in"),
        },
        .include_path = "aws/common/config.h",
    }, .{
        .AWS_HAVE_GCC_OVERFLOW_MATH_EXTENSIONS = 1,
        .AWS_HAVE_GCC_INLINE_ASM = 1,
        .AWS_HAVE_MSVC_INTRINSICS_X64 = null,
        .AWS_HAVE_POSIX_LARGE_FILE_SUPPORT = 1,
        .AWS_HAVE_EXECINFO = getConfigValue(t.os.tag.isBSD()),
        .AWS_HAVE_WINAPI_DESKTOP = getConfigValue(t.os.tag == .windows),
        .AWS_HAVE_LINUX_IF_LINK_H = getConfigValue(t.os.tag == .linux),
        .AWS_HAVE_AVX2_INTRINSICS = have_x86_feat(t, .avx2),
        .AWS_HAVE_AVX512_INTRINSICS = have_x86_feat(t, .avx512f),
        .AWS_HAVE_MM256_EXTRACT_EPI64 = have_x86_feat(t, .avx2),
        .AWS_HAVE_CLMUL = have_x86_feat(t, .pclmul),
        .AWS_HAVE_ARM32_CRC = have_arm_feat(t, .crc),
        .AWS_HAVE_ARMv8_1 = have_arm_feat(t, .has_v8_1a),
        .AWS_ARCH_ARM64 = getConfigValue(t.cpu.arch == .aarch64),
        .AWS_ARCH_INTEL = getConfigValue(t.cpu.arch == .x86),
        .AWS_ARCH_INTEL_X64 = getConfigValue(t.cpu.arch == .x86_64),
        .AWS_USE_CPU_EXTENSIONS = 1,
    });

    const lib = b.addStaticLibrary(.{
        .name = "aws-c-common",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.addConfigHeader(config_h);
    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(aws_c_common_dep.path("include"));
    lib.addIncludePath(aws_c_common_dep.path("source/external/libcbor"));
    lib.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &aws_common_src_vendored,
        .flags = &.{},
    });
    lib.addCSourceFiles(.{
        .root = aws_c_common_dep.path("source"),
        .files = &(aws_common_src ++ aws_common_arch_src ++
            aws_common_external_src),
        .flags = &.{},
    });
    switch (t.os.tag) {
        .windows => {
            lib.addCSourceFiles(.{
                .root = aws_c_common_dep.path("source"),
                .files = &aws_common_os_windows_src,
                .flags = &.{},
            });
            if (t.cpu.arch == .x86) {
                lib.addCSourceFiles(.{
                    .root = aws_c_common_dep.path("source"),
                    .files = &aws_common_arch_mingw_x86_src,
                    .flags = &.{},
                });
            }
            if (t.cpu.arch == .arm or t.cpu.arch == .aarch64) {
                lib.addCSourceFiles(.{
                    .root = aws_c_common_dep.path("source"),
                    .files = &aws_common_arch_mingw_arm_src,
                    .flags = &.{},
                });
            }
            lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_NONE");
        },
        else => {
            lib.linkSystemLibrary("pthread");
            lib.addCSourceFiles(.{
                .root = aws_c_common_dep.path("source"),
                .files = &aws_common_os_posix_src,
                .flags = &.{},
            });
            if (t.cpu.arch == .arm or t.cpu.arch == .aarch64) {
                if (t.os.tag.isDarwin()) {
                    lib.addCSourceFiles(.{
                        .root = aws_c_common_dep.path("source"),
                        .files = &aws_common_arch_darwin_arm_src,
                        .flags = &.{},
                    });
                } else {
                    lib.addCSourceFiles(.{
                        .root = aws_c_common_dep.path("source"),
                        .files = &aws_common_arch_auxv_arm_src,
                        .flags = &.{},
                    });
                }
            }

            if (t.os.tag.isDarwin()) {
                lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_NONE");
            } else {
                lib.defineCMacro("_GNU_SOURCE", null);
                if (t.os.tag.isBSD()) {
                    lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_PTHREAD_ATTR");
                } else {
                    lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_PTHREAD");
                }
                if (t.os.tag != .freebsd and t.os.tag != .openbsd) {
                    lib.defineCMacro("_POSIX_C_SOURCE", "200809L");
                    lib.defineCMacro("_XOPEN_SOURCE", "500");
                }
            }
        },
    }
    lib.installConfigHeader(config_h);
    lib.installHeadersDirectory(b.path("include"), "", .{});
    lib.installHeadersDirectory(aws_c_common_dep.path("include"), "", .{
        .include_extensions = &.{ ".h", ".inl" },
        .exclude_extensions = &.{"allocator.h"},
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn getConfigValue(ok: bool) ?c_int {
    return if (ok) 1 else null;
}

fn have_x86_feat(t: std.Target, feat: std.Target.x86.Feature) ?c_int {
    return switch (t.cpu.arch) {
        .x86, .x86_64 => @intFromBool(std.Target.x86.featureSetHas(t.cpu.features, feat)),
        else => null,
    };
}

fn have_arm_feat(t: std.Target, feat: std.Target.arm.Feature) ?c_int {
    return switch (t.cpu.arch) {
        .arm, .armeb => @intFromBool(std.Target.arm.featureSetHas(t.cpu.features, feat)),
        else => null,
    };
}

const aws_common_src_vendored = [_][]const u8{
    "common.c",
    "allocator.c",
};

const aws_common_src = [_][]const u8{
    //"allocator.c",
    "allocator_sba.c",
    "array_list.c",
    "assert.c",
    "byte_buf.c",
    "cache.c",
    "cbor.c",
    "codegen.c",
    "command_line_parser.c",
    //"common.c",
    "condition_variable.c",
    "date_time.c",
    "device_random.c",
    "encoding.c",
    "error.c",
    "fifo_cache.c",
    "file.c",
    "hash_table.c",
    "host_utils.c",
    "json.c",
    "lifo_cache.c",
    "linked_hash_table.c",
    "logging.c",
    "log_channel.c",
    "log_formatter.c",
    "log_writer.c",
    "lru_cache.c",
    "math.c",
    "memtrace.c",
    "priority_queue.c",
    "process_common.c",
    "ref_count.c",
    "ring_buffer.c",
    "statistics.c",
    "string.c",
    "system_info.c",
    "task_scheduler.c",
    "thread_scheduler.c",
    "thread_shared.c",
    "uri.c",
    "uuid.c",
    "xml_parser.c",
};

const aws_common_external_src = [_][]const u8{
    "external/cJSON.c",

    "external/libcbor/allocators.c",
    "external/libcbor/cbor.c",

    "external/libcbor/cbor/arrays.c",
    "external/libcbor/cbor/bytestrings.c",
    "external/libcbor/cbor/callbacks.c",
    "external/libcbor/cbor/common.c",
    "external/libcbor/cbor/encoding.c",
    "external/libcbor/cbor/floats_ctrls.c",
    "external/libcbor/cbor/ints.c",
    "external/libcbor/cbor/maps.c",
    "external/libcbor/cbor/serialization.c",
    "external/libcbor/cbor/streaming.c",
    "external/libcbor/cbor/strings.c",
    "external/libcbor/cbor/tags.c",

    "external/libcbor/cbor/internal/builder_callbacks.c",
    "external/libcbor/cbor/internal/encoders.c",
    "external/libcbor/cbor/internal/loaders.c",
    "external/libcbor/cbor/internal/memory_utils.c",
    "external/libcbor/cbor/internal/stack.c",
    "external/libcbor/cbor/internal/unicode.c",
};

const aws_common_os_windows_src = [_][]const u8{
    "windows/clock.c",
    "windows/condition_variable.c",
    "windows/cross_process_lock.c",
    "windows/device_random.c",
    "windows/environment.c",
    "windows/file.c",
    "windows/mutex.c",
    "windows/process.c",
    "windows/rw_lock.c",
    "windows/system_info.c",
    "windows/system_resource_utils.c",
    "windows/thread.c",
    "windows/time.c",

    "platform_fallback_stubs/system_info.c",
};

const aws_common_os_posix_src = [_][]const u8{
    "posix/clock.c",
    "posix/condition_variable.c",
    "posix/cross_process_lock.c",
    "posix/device_random.c",
    "posix/environment.c",
    "posix/file.c",
    "posix/mutex.c",
    "posix/process.c",
    "posix/rw_lock.c",
    "posix/system_info.c",
    "posix/system_resource_utils.c",
    "posix/thread.c",
    "posix/time.c",

    "platform_fallback_stubs/system_info.c",
};

const aws_common_arch_src = [_][]const u8{
    "arch/generic/cpuid.c",
};

const aws_common_arch_mingw_x86_src = [_][]const u8{
    "arch/intel/cpuid.c",
    "arch/intel/asm/cpuid.c",
};

const aws_common_arch_mingw_arm_src = [_][]const u8{
    "arch/arm/windows/cpuid.c",
};

const aws_common_arch_darwin_arm_src = [_][]const u8{
    "arch/arm/darwin/cpuid.c",
};

const aws_common_arch_auxv_arm_src = [_][]const u8{
    "arch/arm/auxv/cpuid.c",
};
