# zig-glfw-vulkan-openxr

Cross-compatible **Zig (nightly) + GLFW + Vulkan** triangle demo, wired up with:

- [`glfw-zig`](https://github.com/zigadel/glfw-zig) for windowing and input  
- [`vulkan-zig`](https://github.com/Snektron/vulkan-zig) for Vulkan bindings + codegen  
- A small but realistic **graphics stack**: instance, device, swapchain, pipeline, command buffers, resize handling, etc.

---

## What this example shows

- How to use **glfw-zig** to create a Vulkan-compatible window (no client API).
- How to integrate **vulkan-zig**:
  - Auto-generate `vk.zig` from `vk.xml` at build time.
  - Use the generated loader (`vkb`, `vki`, `vkd`) in idiomatic Zig.
- A clean separation of concerns:
  - `graphics_context.zig` – instance, device, queues, surface, allocator.
  - `swapchain.zig` – swapchain creation, resize-safe recreation, per-frame sync.
  - `vertex.zig` – vertex format and binding/attribute descriptions.
- **SPIR-V shader** compilation via `glslc`, embedded with `@embedFile`.
- Cross-platform behavior:
  - **Windows**: LunarG Vulkan SDK + `vulkan-1.dll`
  - **macOS**: MoltenVK (`libvulkan.dylib` → `libMoltenVK.dylib`)
  - **Linux**: system Vulkan loader (`libvulkan.so`)

---

## Requirements

### 1. Zig

- A recent **Zig 0.16.0-dev** build (same major/dev line as the one used in `build.zig.zon`).
- Make sure `zig` is on your `PATH`.

### 2. Vulkan loader + drivers

You need a working Vulkan runtime + loader for your platform.

**Windows**

- Install the LunarG Vulkan SDK: <https://vulkan.lunarg.com/sdk/home>  
  This gives you:
  - `vulkan-1.dll` (loader)
  - GPU drivers integration
  - `glslc` and tools

**macOS**

- Install the Vulkan SDK for macOS (which includes MoltenVK), **or**:
  - Install MoltenVK + loader via your package manager (e.g. Homebrew).
- You should end up with:
  - `libvulkan.dylib` in a system or SDK location
  - `libMoltenVK.dylib` available to the loader

**Linux**

- Install Vulkan loader + dev packages via your distro:
  - e.g. `vulkan-loader`, `vulkan-tools`, appropriate Mesa/NVIDIA/AMD drivers.

### 3. `glslc` (shader compiler)

The build calls `glslc` to compile the shaders in `shaders/` to SPIR-V.

- If you installed the Vulkan SDK, `glslc` is already there.
- Just ensure it’s on your `PATH`:
  - **macOS example** (`~/.zprofile`):

    ```sh
    export PATH="$PATH:$HOME/VulkanSDK/<VERSION>/macOS/bin"
    ```

  - **Windows**: the SDK installer can add this automatically; otherwise add the `bin` folder manually to `PATH`.

---

## vk.xml / vulkan-zig integration

`vulkan-zig` generates `vk.zig` from the official **Vulkan registry XML** (`vk.xml`).

This project uses a **“best of both worlds”** approach:

- If `registry/vk.xml` exists (you’ve pinned a specific version), it is used.
- Otherwise, the **first `zig build`** will:
  - Create `registry/` (if needed).
  - Download the latest `vk.xml` from the Khronos GitHub repo into `registry/vk.xml`.
  - Run the `vulkan-zig` generator to produce `vk.zig` in the Zig cache.

`registry/vk.xml` is **git-ignored** so your repo stays light, but you still get reproducible builds once it’s been fetched once.

You normally **don’t need to do anything manually**. Just:

```sh
zig build
```

and let the build script handle it.

If you want to pin a specific registry version (e.g. for long-term reproducibility):

1. Download `vk.xml` from the Vulkan-Docs repo.

2. Place it at `registry/vk.xml`.

3. Commit everything except `vk.xml` itself (it remains in `.gitignore`)

## Cloning & running the example

```sh
git clone https://github.com/James-Riordan/zig-glfw-vulkan-openxr.git
cd zig-glfw-vulkan-openxr
```

Build & run in one go:

```sh
zig build run
```

On the first build, you will see steps like:

- `run exe vulkan-zig-generator (vk.zig)`
- `run curl (vk.xml)`
- `run glslc (triangle_vert.spv)`
- `run glslc (triangle_frag.spv)`

After that, incremental builds will be much faster.

You should see a window with a **colored triangle** rendered via Vulkan.
Resizing the window will trigger a **safe swapchain recreation** (tested on Windows + macOS via MoltenVK)

## Repository layout

High-level structure (only the interesting bits):

```txt
zig-glfw-vulkan-openxr/
├─ src/
│  ├─ main.zig                    # Entry point; GLFW loop, wiring everything together
│  └─ graphics/
│     ├─ graphics_context.zig     # Vulkan instance, device, queues, surface, allocator
│     ├─ swapchain.zig            # Swapchain + per-frame sync + resize-safe recreation
│     └─ vertex.zig               # Vertex struct + binding/attribute descriptions
├─ shaders/
│  ├─ triangle.vert               # GLSL vertex shader
│  └─ triangle.frag               # GLSL fragment shader
├─ registry/
│  └─ vk.xml                      # (ignored by git) Vulkan registry; auto-fetched if absent
├─ build.zig                      # Build script: deps, shader compilation, vk.xml handling
├─ build.zig.zon                  # Zig package dependencies (glfw-zig, vulkan-zig)
└─ README.md                      # You are here
```

## Troubleshooting

`curl: command not found`

- Install `curl` and ensure it’s on your `PATH`.
The build uses it once to download `vk.xml` if it’s missing.

`glslc: command not found`

- Install the Vulkan SDK or `glslc` via your package manager.

- Confirm `glslc` is visible in your terminal shell (`glslc --version`).

`IncompatibleDriver` / **Vulkan initialization errors**

- Usually means:

    - No Vulkan-capable GPU/driver.

    - MoltenVK / Vulkan loader not properly installed or discoverable.

- On macOS, double-check your **Vulkan SDK / MoltenVK** install and that `libvulkan.dylib` + `libMoltenVK.dylib` are in the expected locations.

**Weird crashes on window resize**

- This codebase already includes a safe swapchain recreation path (create new swapchain first, then tear down the old one).

- If you see issues, they’re likely from:

    - A partially broken Vulkan install.

    - Very old drivers / SDK.

- Updating your Vulkan SDK + GPU drivers usually resolves it.

That’s it. This repo is meant to be a **clean, minimal reference** for:

- `glfw-zig` windowing

- `vulkan-zig` integration

- A small but realistic Vulkan render loop in Zig

From here you can start layering in descriptor sets, depth buffers, multiple pipelines, or (eventually) OpenXR on top