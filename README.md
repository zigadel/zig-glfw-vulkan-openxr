# mach-glfw Vulkan example

This is an example for how to use [zig-glfw](https://github.com/James-Riordan/zig-glfw) and [vulkan-zig](https://github.com/snektron/vulkan-zig) together to create a basic Vulkan window.

![](https://user-images.githubusercontent.com/3173176/139573985-d862f35a-e78e-40c2-bc0c-9c4fb68d6ecd.png)

## Getting started

### Install the Vulkan SDK

You must install the LunarG Vulkan SDK: https://vulkan.lunarg.com/sdk/home

## Download vk.xml

1. Download vk.xml directly from the [Vulkan-Headers Github repository](https://github.com/KhronosGroup/Vulkan-Headers/blob/main/registry/vk.xml)

2. Place `vk.xml` in the `registry/` folder


### Clone the repository and dependencies

```sh
git clone https://github.com/James-Riordan/nightly-zig-glfw-vulkan-example

cd nightly-zig-glfw-vulkan-example
```

### Ensure glslc is on your PATH

On MacOS, you may e.g. place the following in your `~/.zprofile` file:

```sh
export PATH=$PATH:$HOME/VulkanSDK/<VERSION>/macOS/bin/
```

### Run the example

```sh
zig build run
```

### Cross compilation

Vulkan requires a fairly heavy-weight SDK, at this time cross compilation is not possible.
