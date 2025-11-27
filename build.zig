const std = @import("std");

fn linkVulkanLoader(
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    b: *std.Build,
) void {
    const os_tag = target.result.os.tag;

    switch (os_tag) {
        .windows => {
            // Try to locate the Vulkan SDK and add its Lib directory.
            const sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;
            if (sdk) |sdk_path| {
                defer b.allocator.free(sdk_path);

                const lib_dir = std.fs.path.join(b.allocator, &.{ sdk_path, "Lib" }) catch null;
                if (lib_dir) |ld| {
                    defer b.allocator.free(ld);
                    exe.addLibraryPath(.{ .cwd_relative = ld });
                }
            }

            // Windows loader name.
            exe.linkSystemLibrary("vulkan-1");
        },
        .linux => {
            exe.linkSystemLibrary("vulkan");
        },
        .macos => {
            // Typically MoltenVK / Vulkan loader (e.g. via VK SDK / Homebrew).
            exe.linkSystemLibrary("vulkan");
        },
        else => {
            // Other OSes: do nothing. If a Vulkan loader is required but missing,
            // link will fail loud and clear.
        },
    }
}

/// Ensure we have a *workspace* ./registry/vk.xml:
/// - If ./registry/vk.xml exists, just use it.
/// - Otherwise:
///   - mkdir ./registry (if needed),
///   - run `curl -L <vk.xml> -o registry/vk.xml` once,
///   - then use that.
///
/// This returns a LazyPath suitable for `.registry` in the `vulkan` dependency.
fn ensureVkRegistry(b: *std.Build) std.Build.LazyPath {
    const xml_rel = "registry/vk.xml";
    const registry_dir = "registry";
    const cwd = std.fs.cwd();

    // 1) If the file already exists in the repo, we're done.
    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {}, // expected first-time case
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{
                xml_rel,
                @errorName(err),
            });
            @panic("cannot access registry/vk.xml");
        },
    }

    // 2) Make sure ./registry exists.
    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{
                registry_dir,
                @errorName(err),
            });
            @panic("cannot create registry directory");
        },
    };

    // 3) Download vk.xml into ./registry/vk.xml using curl, synchronously.
    //    (No build step, no .zig-cache weirdness.)
    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml",
        "-o",
        xml_rel,
    };

    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("error: failed to spawn curl: {s}\n", .{@errorName(err)});
        @panic("curl not available or failed to start");
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("error: curl exited with code {d}\n", .{code});
            @panic("failed to download vk.xml");
        },
        else => {
            std.debug.print("error: curl terminated abnormally: {any}\n", .{term});
            @panic("failed to download vk.xml");
        },
    }

    // 4) Sanity check that vk.xml is now really there.
    if (cwd.openFile(xml_rel, .{})) |file2| {
        file2.close();
    } else |err| {
        std.debug.print("error: vk.xml download seems to have succeeded, but cannot reopen {s}: {s}\n", .{
            xml_rel,
            @errorName(err),
        });
        @panic("vk.xml missing after download");
    }

    return b.path(xml_rel);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ─────────────────────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────────────────────

    // glfw-zig (your repo), as declared in build.zig.zon under .glfw_zig.
    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const glfw_mod = glfw_dep.module("glfw");
    const glfw_lib = glfw_dep.artifact("glfw-zig");

    // vulkan-zig (Snektron), declared in build.zig.zon under .vulkan.
    // We *always* provide a concrete registry path in the workspace:
    //   - If registry/vk.xml already exists, we reuse it.
    //   - Otherwise, we download it once.
    const vk_registry = ensureVkRegistry(b);

    const vk_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
        .registry = vk_registry,
    });

    const vk_mod = vk_dep.module("vulkan-zig");

    // ─────────────────────────────────────────────────────────────────────
    // Root module for the example
    // ─────────────────────────────────────────────────────────────────────

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("glfw", glfw_mod);
    exe_mod.addImport("vulkan", vk_mod);

    // ─────────────────────────────────────────────────────────────────────
    // Shader compilation (glslc → SPIR-V → @embedFile)
    // ─────────────────────────────────────────────────────────────────────

    // Vertex shader → triangle_vert.spv → anonymous import "triangle_vert".
    const compile_vert_shader = b.addSystemCommand(&.{"glslc"});
    compile_vert_shader.addFileArg(b.path("shaders/triangle.vert"));
    compile_vert_shader.addArgs(&.{ "--target-env=vulkan1.1", "-o" });
    const triangle_vert_spv = compile_vert_shader.addOutputFileArg("triangle_vert.spv");
    exe_mod.addAnonymousImport("triangle_vert", .{
        .root_source_file = triangle_vert_spv,
    });

    // Fragment shader → triangle_frag.spv → anonymous import "triangle_frag".
    const compile_frag_shader = b.addSystemCommand(&.{"glslc"});
    compile_frag_shader.addFileArg(b.path("shaders/triangle.frag"));
    compile_frag_shader.addArgs(&.{ "--target-env=vulkan1.1", "-o" });
    const triangle_frag_spv = compile_frag_shader.addOutputFileArg("triangle_frag.spv");
    exe_mod.addAnonymousImport("triangle_frag", .{
        .root_source_file = triangle_frag_spv,
    });

    // ─────────────────────────────────────────────────────────────────────
    // Executable + run step
    // ─────────────────────────────────────────────────────────────────────

    const exe = b.addExecutable(.{
        .name = "zig-glfw-vulkan-openxr",
        .root_module = exe_mod,
    });

    // Pull in glfw-zig (which brings GLFW C and platform libs along).
    exe.linkLibrary(glfw_lib);

    // Pull in the Vulkan loader for the host OS.
    linkVulkanLoader(exe, target, b);

    // Install the exe as the default artifact.
    b.installArtifact(exe);

    // `zig build run` convenience.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Vulkan triangle demo");
    run_step.dependOn(&run_cmd.step);
}
