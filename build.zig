const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── SDL3 (from allyourcodebase package) ──────────────────────────────
    const sdl_dep = b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    const sdl_lib = sdl_dep.artifact("SDL3");

    // ── FreeType (from allyourcodebase package) ─────────────────────────
    const ft_dep = b.dependency("freetype", .{ .target = target, .optimize = optimize });
    const ft_lib = ft_dep.artifact("freetype");

    // ── Lua 5.4 (compiled from source) ──────────────────────────────────
    const lua_src = b.dependency("lua_src", .{});
    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lua_lib.root_module.addIncludePath(lua_src.path("src"));
    if (target.result.os.tag != .windows) {
        lua_lib.root_module.addCMacro("LUA_USE_POSIX", "1");
    }
    const lua_core_files = &[_][]const u8{
        "src/lapi.c",     "src/lcode.c",   "src/lctype.c",   "src/ldebug.c",
        "src/ldo.c",      "src/ldump.c",   "src/lfunc.c",    "src/lgc.c",
        "src/llex.c",     "src/lmem.c",    "src/lobject.c",  "src/lopcodes.c",
        "src/lparser.c",  "src/lstate.c",  "src/lstring.c",  "src/ltable.c",
        "src/ltm.c",      "src/lundump.c", "src/lvm.c",      "src/lzio.c",
        "src/lauxlib.c",  "src/lbaselib.c", "src/lcorolib.c", "src/ldblib.c",
        "src/liolib.c",   "src/lmathlib.c", "src/loadlib.c",  "src/loslib.c",
        "src/lstrlib.c",  "src/ltablib.c", "src/lutf8lib.c", "src/linit.c",
    };
    lua_lib.addCSourceFiles(.{
        .root = lua_src.path(""),
        .files = lua_core_files,
    });

    // ── PCRE2 (compiled from source) ────────────────────────────────────
    const pcre2_src = b.dependency("pcre2_src", .{});
    const pcre2_lib = b.addLibrary(.{
        .name = "pcre2-8",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    pcre2_lib.root_module.addIncludePath(pcre2_src.path("src"));
    pcre2_lib.root_module.addCMacro("PCRE2_CODE_UNIT_WIDTH", "8");
    pcre2_lib.root_module.addCMacro("PCRE2_STATIC", "1");
    pcre2_lib.root_module.addCMacro("HAVE_CONFIG_H", "1");

    // Copy config.h.generic -> config.h via WriteFiles
    const pcre2_config = b.addWriteFiles();
    _ = pcre2_config.addCopyFile(pcre2_src.path("src/config.h.generic"), "config.h");
    _ = pcre2_config.addCopyFile(pcre2_src.path("src/pcre2.h.generic"), "pcre2.h");
    _ = pcre2_config.addCopyFile(pcre2_src.path("src/pcre2_chartables.c.dist"), "pcre2_chartables.c");
    pcre2_lib.root_module.addIncludePath(pcre2_config.getDirectory());

    // Chartables as separate source (from generated copy)
    pcre2_lib.addCSourceFile(.{
        .file = pcre2_config.addCopyFile(pcre2_src.path("src/pcre2_chartables.c.dist"), "pcre2_chartables_gen.c"),
        .flags = &.{ "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8", "-DPCRE2_STATIC" },
    });

    const pcre2_files = &[_][]const u8{
        "src/pcre2_auto_possess.c", "src/pcre2_chkdint.c",
        "src/pcre2_compile.c",      "src/pcre2_config.c",
        "src/pcre2_context.c",      "src/pcre2_convert.c",
        "src/pcre2_dfa_match.c",    "src/pcre2_error.c",
        "src/pcre2_extuni.c",       "src/pcre2_find_bracket.c",
        "src/pcre2_maketables.c",   "src/pcre2_match.c",
        "src/pcre2_match_data.c",   "src/pcre2_newline.c",
        "src/pcre2_ord2utf.c",      "src/pcre2_pattern_info.c",
        "src/pcre2_script_run.c",   "src/pcre2_serialize.c",
        "src/pcre2_string_utils.c", "src/pcre2_study.c",
        "src/pcre2_substitute.c",   "src/pcre2_substring.c",
        "src/pcre2_tables.c",       "src/pcre2_ucd.c",
        "src/pcre2_jit_compile.c",
        "src/pcre2_valid_utf.c",    "src/pcre2_xclass.c",
    };
    pcre2_lib.addCSourceFiles(.{
        .root = pcre2_src.path(""),
        .files = pcre2_files,
        .flags = &.{ "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8", "-DPCRE2_STATIC" },
    });

    // ── Main Executable ─────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "glyph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Windows GUI subsystem (no console window on double-click)
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }

    // Link all libraries
    exe.root_module.linkLibrary(sdl_lib);
    exe.root_module.linkLibrary(ft_lib);
    exe.root_module.linkLibrary(lua_lib);
    exe.root_module.linkLibrary(pcre2_lib);

    // Expose headers to the Zig source (for @cImport)
    exe.root_module.addIncludePath(lua_src.path("src")); // lua.h
    exe.root_module.addIncludePath(pcre2_src.path("src")); // pcre2.h (source)
    exe.root_module.addIncludePath(pcre2_config.getDirectory()); // pcre2.h (generated)

    // Windows system libraries
    if (target.result.os.tag == .windows) {
        const win_libs = [_][]const u8{
            "gdi32", "user32", "shell32", "advapi32", "ole32", "comdlg32",
        };
        for (&win_libs) |lib_name| {
            exe.root_module.linkSystemLibrary(lib_name, .{});
        }
    }

    b.installArtifact(exe);

    // ── Run step ────────────────────────────────────────────────────────
    const run_step = b.step("run", "Run glyph");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
