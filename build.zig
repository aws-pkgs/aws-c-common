const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;
    const upstream = b.dependency("upstream", .{});
    const config_h = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("include/aws/common/config.h.in") },
        .include_path = "aws/common/config.h",
    }, .{
        .AWS_HAVE_GCC_OVERFLOW_MATH_EXTENSIONS = 1,
        .AWS_HAVE_GCC_INLINE_ASM = 1,
        .AWS_HAVE_MSVC_INTRINSICS_X64 = null,
        .AWS_HAVE_POSIX_LARGE_FILE_SUPPORT = t.os.tag != .windows,
        .AWS_HAVE_EXECINFO = t.abi.isGnu(),
        .AWS_HAVE_WINAPI_DESKTOP = t.os.tag == .windows,
        .AWS_HAVE_LINUX_IF_LINK_H = t.os.tag == .linux,
        .AWS_HAVE_AVX2_INTRINSICS = have_x86_feat(t, .avx2),
        .AWS_HAVE_AVX512_INTRINSICS = have_x86_feat(t, .avx512f),
        .AWS_HAVE_MM256_EXTRACT_EPI64 = have_x86_feat(t, .avx2),
    });
    const lib = b.addStaticLibrary(.{
        .name = "aws-c-common",
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    lib.addConfigHeader(config_h);
    lib.addIncludePath(.{ .path = "include" });
    lib.addIncludePath(upstream.path("include"));
    lib.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &common_src,
        .flags = &.{},
    });
    lib.addCSourceFiles(.{
        .files = &common_vendor_src,
        .flags = &.{},
    });
    if (t.os.tag == .windows) {
        lib.linkSystemLibrary("kernel32");
        lib.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = &windows_src,
            .flags = &.{},
        });
        lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_NONE");
    } else {
        if (t.os.tag == .macos) {
            lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_NONE");
        } else {
            lib.defineCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_PTHREAD");
        }
        if (t.os.tag == .linux) {
            lib.addCSourceFiles(.{
                .root = upstream.path("."),
                .files = &system_info_linux,
                .flags = &.{},
            });
        } else {
            lib.addCSourceFiles(.{
                .root = upstream.path("."),
                .files = &system_info_stub,
                .flags = &.{},
            });
        }
        lib.linkSystemLibrary("pthread");
        lib.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = &posix_src,
            .flags = &.{},
        });
        switch (t.os.tag) {
            .macos => {
                lib.linkSystemLibrary("dl");
            },
            .linux => {
                lib.linkSystemLibrary("dl");
                lib.linkSystemLibrary("m");
                lib.linkSystemLibrary("rt");
                lib.defineCMacro("AWS_PTHREAD_SETNAME_TAKES_2ARGS", null);
            },
            .freebsd => {
                lib.linkSystemLibrary("dl");
                lib.linkSystemLibrary("thr");
                lib.linkSystemLibrary("execinfo");
                lib.defineCMacro("AWS_PTHREAD_SETNAME_TAKES_2ARGS", null);
            },
            .netbsd => {
                lib.linkSystemLibrary("dl");
                lib.linkSystemLibrary("m");
                lib.linkSystemLibrary("execinfo");
                lib.defineCMacro("AWS_PTHREAD_SETNAME_TAKES_3ARGS", null);
            },
            .openbsd => {
                lib.linkSystemLibrary("m");
                lib.linkSystemLibrary("execinfo");
                lib.defineCMacro("AWS_PTHREAD_SET_NAME_TAKES_2ARGS", null);
            },
            else => @panic("unsupported os"),
        }
    }
    if (t.os.tag == .linux or t.os.tag == .netbsd) {
        lib.defineCMacro("_POSIX_C_SOURCE", "200809L");
        lib.defineCMacro("_XOPEN_SOURCE", "500");
    }
    lib.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &arch_generic_src,
        .flags = &.{},
    });
    switch (t.cpu.arch) {
        .x86_64 => {
            lib.addCSourceFiles(.{
                .root = upstream.path("."),
                .files = &arch_x86_64_src,
                .flags = &.{},
            });
        },
        .aarch64 => {
            lib.addCSourceFiles(.{
                .root = upstream.path("."),
                .files = &arch_aarch64_src,
                .flags = &.{},
            });
        },
        else => @panic("unsupported arch"),
    }
    if (have_x86_feat(t, .avx2) == 1) {
        lib.defineCMacro("USE_SIMD_ENCODING", null);
        lib.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = &arch_x86_64_avx2,
            .flags = &.{},
        });
    }
    lib.defineCMacro("CJSON_HIDE_SYMBOLS", null);
    lib.defineCMacro("_GNU_SOURCE", null);
    lib.installConfigHeader(config_h, .{});
    lib.installHeadersDirectoryOptions(.{
        .source_dir = .{ .path = "include" },
        .install_dir = .header,
        .install_subdir = "",
    });
    lib.installHeadersDirectoryOptions(.{
        .source_dir = upstream.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn have_x86_feat(t: std.Target, feat: std.Target.x86.Feature) c_int {
    return @intFromBool(switch (t.cpu.arch) {
        .x86, .x86_64 => std.Target.x86.featureSetHas(t.cpu.features, feat),
        else => false,
    });
}

const common_src = [_][]const u8{
    //"source/allocator.c",
    "source/allocator_sba.c",
    "source/array_list.c",
    "source/assert.c",
    "source/byte_buf.c",
    "source/cache.c",
    "source/codegen.c",
    "source/command_line_parser.c",
    //"source/common.c",
    "source/condition_variable.c",
    "source/date_time.c",
    "source/device_random.c",
    "source/encoding.c",
    "source/error.c",
    "source/fifo_cache.c",
    "source/file.c",
    "source/hash_table.c",
    "source/json.c",
    "source/lifo_cache.c",
    "source/linked_hash_table.c",
    "source/logging.c",
    "source/log_channel.c",
    "source/log_formatter.c",
    "source/log_writer.c",
    "source/lru_cache.c",
    "source/math.c",
    "source/memtrace.c",
    "source/priority_queue.c",
    "source/process_common.c",
    "source/promise.c",
    "source/ref_count.c",
    "source/ring_buffer.c",
    "source/statistics.c",
    "source/string.c",
    "source/system_info.c",
    "source/task_scheduler.c",
    "source/thread_scheduler.c",
    "source/thread_shared.c",
    "source/uri.c",
    "source/uuid.c",
    "source/xml_parser.c",
};

const common_vendor_src = [_][]const u8{
    "src/allocator.c",
    "src/common.c",
};

const common_external_src = [_][]const u8{
    "source/external/cJSON.c",
};

const system_info_linux = [_][]const u8{
    "source/linux/system_info.c",
};

const system_info_stub = [_][]const u8{
    "source/platform_fallback_stubs/system_info.c",
};

const windows_src = [_][]const u8{
    "source/windows/clock.c",
    "source/windows/condition_variable.c",
    "source/windows/cross_process_lock.c",
    "source/windows/device_random.c",
    "source/windows/environment.c",
    "source/windows/file.c",
    "source/windows/mutex.c",
    "source/windows/process.c",
    "source/windows/rw_lock.c",
    "source/windows/system_info.c",
    "source/windows/system_resource_utils.c",
    "source/windows/thread.c",
    "source/windows/time.c",
};

const posix_src = [_][]const u8{
    "source/posix/clock.c",
    "source/posix/condition_variable.c",
    "source/posix/cross_process_lock.c",
    "source/posix/device_random.c",
    "source/posix/environment.c",
    "source/posix/file.c",
    "source/posix/mutex.c",
    "source/posix/process.c",
    "source/posix/rw_lock.c",
    "source/posix/system_info.c",
    "source/posix/system_resource_utils.c",
    "source/posix/thread.c",
    "source/posix/time.c",
};

const arch_generic_src = [_][]const u8{
    "source/arch/generic/cpuid.c",
};

const arch_x86_64_src = [_][]const u8{
    "source/arch/intel/cpuid.c",
    "source/arch/intel/asm/cpuid.c",
};

const arch_aarch64_src = [_][]const u8{
    "source/arch/arm/asm/cpuid.c",
};

const arch_x86_64_avx2 = [_][]const u8{
    "source/arch/intel/encoding_avx2.c",
};
