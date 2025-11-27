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

            exe.linkSystemLibrary("vulkan-1");
        },
        .linux => {
            exe.linkSystemLibrary("vulkan");
        },
        .macos => {
            // Typically MoltenVK / Vulkan loader (e.g. via VK SDK).
            exe.linkSystemLibrary("vulkan");
        },
        else => {
            // Other OSes: do nothing. If a Vulkan loader is required but
            // missing, link will fail loudly, which is fine.
        },
    }
}

/// Ensure we have a vk.xml for vulkan-zig:
/// - If ./registry/vk.xml exists, use it.
/// - Otherwise, create ./registry and download vk.xml via curl, and use that.
///
/// Returns a LazyPath suitable to pass as `.registry` to the `vulkan` dep.
fn ensureVkRegistry(b: *std.Build) std.Build.LazyPath {
    const registry_rel = "registry/vk.xml";

    // 1) Check if a local registry/vk.xml already exists.
    var has_local: bool = false;
    {
        const cwd = std.fs.cwd();
        if (cwd.openFile(registry_rel, .{})) |f| {
            f.close();
            has_local = true;
        } else |_| {
            has_local = false;
        }
    }

    if (has_local) {
        // Use the committed file (no network). This matches your old behavior.
        return b.path(registry_rel);
    }

    // 2) No local vk.xml: create ./registry and download a fresh copy.
    const cwd = std.fs.cwd();
    cwd.makePath("registry") catch |err| {
        std.debug.print(
            "warning: failed to create 'registry/' directory: {s}\n",
            .{@errorName(err)},
        );
    };

    const dl = b.addSystemCommand(&.{"curl"});
    // Adjust the URL if you want to pin to a specific Vulkan-Docs revision.
    dl.addArgs(&.{
        "-L",
        "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml",
        "-o",
    });
    const vk_xml = dl.addOutputFileArg(registry_rel);

    return vk_xml;
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
    // We now *always* provide a registry LazyPath, but the file is either:
    //   - your committed ./registry/vk.xml, or
    //   - auto-downloaded via curl into ./registry/vk.xml
    const vk_registry = ensureVkRegistry(b);

    const vk_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
        .registry = vk_registry,
    });

    // Module name exported by vulkan-zig's build.zig.
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
