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
            // This assumes a layout like: %VULKAN_SDK%\Lib\vulkan-1.lib
            const sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;
            if (sdk) |sdk_path| {
                // Join "<sdk_path>" + "Lib" into a single path string.
                const lib_dir = std.fs.path.join(b.allocator, &.{ sdk_path, "Lib" }) catch null;
                if (lib_dir) |ld| {
                    // LazyPath no longer has an 'absolute' variant; cwd_relative
                    // is used for arbitrary paths (absolute or relative).
                    exe.addLibraryPath(.{ .cwd_relative = ld });
                }
            }

            // Windows loader name.
            exe.linkSystemLibrary("vulkan-1");
        },
        .linux => {
            // Linux loader name.
            exe.linkSystemLibrary("vulkan");
        },
        .macos => {
            // On macOS this typically comes from MoltenVK (libvulkan.dylib).
            exe.linkSystemLibrary("vulkan");
        },
        else => {
            // Other OSes: do nothing for now. The build will fail if a loader
            // is required but missing, which is fine.
        },
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ─────────────────────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────────────────────

    // glfw-zig (your repo), as declared in build.zig.zon under .glfw_zig.
    // Exposes:
    //   - module "glfw"
    //   - artifact "glfw-zig" (which already links the GLFW C library)
    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const glfw_mod = glfw_dep.module("glfw");
    const glfw_lib = glfw_dep.artifact("glfw-zig");

    // vulkan-zig (Snektron), as declared in build.zig.zon under .vulkan.
    // We point it at our local registry/vk.xml, same as your original project.
    const vk_dep = b.dependency("vulkan", .{
        .registry = b.pathFromRoot("registry/vk.xml"),
        .target = target,
        .optimize = optimize,
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
    // Match your old behavior: run from the install dir.
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Vulkan triangle demo");
    run_step.dependOn(&run_cmd.step);
}
