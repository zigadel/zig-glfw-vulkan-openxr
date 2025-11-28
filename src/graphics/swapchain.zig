const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Allocator = std.mem.Allocator;

pub const Swapchain = struct {
    pub const PresentState = enum {
        optimal,
        suboptimal,
    };

    gc: *const GraphicsContext,
    allocator: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    image_index: u32,
    next_image_acquired: vk.Semaphore,

    pub fn init(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D) !Swapchain {
        // First-time creation: no old swapchain
        return try buildSwapchain(gc, allocator, extent, .null_handle);
    }

    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        const gc = self.gc;
        const allocator = self.allocator;
        const old_handle = self.handle;

        // Make sure no in-flight work still touches the old swapchain.
        try gc.vkd.deviceWaitIdle(gc.dev);

        // Build a brand-new swapchain *first*. Do not tear down the old one yet.
        const new_swapchain = try buildSwapchain(gc, allocator, new_extent, old_handle);

        // Now it is safe to tear down the old per-image resources.
        self.deinitExceptSwapchain();
        gc.vkd.destroySwapchainKHR(gc.dev, old_handle, null);

        // Install the new swapchain in-place.
        self.* = new_swapchain;
    }

    fn deinitExceptSwapchain(self: Swapchain) void {
        // Destroy per-image resources and free the backing array.
        for (self.swap_images) |si| si.deinit(self.gc);
        self.allocator.free(self.swap_images);

        // Destroy the extra semaphore used for the next image.
        self.gc.vkd.destroySemaphore(self.gc.dev, self.next_image_acquired, null);
    }

    pub fn deinit(self: Swapchain) void {
        // Final teardown at program exit.
        self.deinitExceptSwapchain();
        self.gc.vkd.destroySwapchainKHR(self.gc.dev, self.handle, null);
    }

    pub fn waitForAllFences(self: Swapchain) !void {
        for (self.swap_images) |si| si.waitForFence(self.gc) catch {};
    }

    pub fn currentImage(self: Swapchain) vk.Image {
        return self.swap_images[self.image_index].image;
    }

    pub fn currentSwapImage(self: Swapchain) *const SwapImage {
        return &self.swap_images[self.image_index];
    }

    pub fn present(self: *Swapchain, cmdbuf: vk.CommandBuffer) !PresentState {
        // Step 1: Make sure the current frame has finished rendering.
        const current = self.currentSwapImage();
        try current.waitForFence(self.gc);
        try self.gc.vkd.resetFences(self.gc.dev, 1, @ptrCast(&current.frame_fence));

        // Step 2: Submit the command buffer.
        const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
        try self.gc.vkd.queueSubmit(self.gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.image_acquired),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&current.render_finished),
        }}, current.frame_fence);

        // Step 3: Present the current frame.
        _ = try self.gc.vkd.queuePresentKHR(self.gc.present_queue.handle, &vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&self.image_index),
            .p_results = null,
        });

        // Step 4: Acquire next frame.
        const result = try self.gc.vkd.acquireNextImageKHR(
            self.gc.dev,
            self.handle,
            std.math.maxInt(u64),
            self.next_image_acquired,
            .null_handle,
        );

        std.mem.swap(
            vk.Semaphore,
            &self.swap_images[result.image_index].image_acquired,
            &self.next_image_acquired,
        );
        self.image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }
};

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(gc: *const GraphicsContext, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try gc.vkd.createImageView(gc.dev, &.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer gc.vkd.destroyImageView(gc.dev, view, null);

        const image_acquired = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, image_acquired, null);

        const render_finished = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, render_finished, null);

        const frame_fence = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer gc.vkd.destroyFence(gc.dev, frame_fence, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, gc: *const GraphicsContext) void {
        self.waitForFence(gc) catch {};
        gc.vkd.destroyImageView(gc.dev, self.view, null);
        gc.vkd.destroySemaphore(gc.dev, self.image_acquired, null);
        gc.vkd.destroySemaphore(gc.dev, self.render_finished, null);
        gc.vkd.destroyFence(gc.dev, self.frame_fence, null);
    }

    fn waitForFence(self: SwapImage, gc: *const GraphicsContext) !void {
        _ = try gc.vkd.waitForFences(
            gc.dev,
            1,
            @ptrCast(&self.frame_fence),
            @enumFromInt(vk.TRUE),
            std.math.maxInt(u64),
        );
    }
};

fn buildSwapchain(
    gc: *const GraphicsContext,
    allocator: Allocator,
    extent: vk.Extent2D,
    old_handle: vk.SwapchainKHR,
) !Swapchain {
    const caps = try gc.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
    const actual_extent = findActualExtent(caps, extent);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(gc, allocator);
    const present_mode = try findPresentMode(gc, allocator);

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        image_count = @min(image_count, caps.max_image_count);
    }

    const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
    const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family)
        .concurrent
    else
        .exclusive;

    const handle = try gc.vkd.createSwapchainKHR(gc.dev, &.{
        .flags = .{},
        .surface = gc.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = qfi.len,
        .p_queue_family_indices = &qfi,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = @enumFromInt(vk.TRUE),
        .old_swapchain = old_handle,
    }, null);
    errdefer gc.vkd.destroySwapchainKHR(gc.dev, handle, null);

    const swap_images = try initSwapchainImages(gc, handle, surface_format.format, allocator);
    errdefer {
        for (swap_images) |si| si.deinit(gc);
        allocator.free(swap_images);
    }

    var next_image_acquired = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
    errdefer gc.vkd.destroySemaphore(gc.dev, next_image_acquired, null);

    const result = try gc.vkd.acquireNextImageKHR(
        gc.dev,
        handle,
        std.math.maxInt(u64),
        next_image_acquired,
        .null_handle,
    );

    if (result.result != .success and result.result != .suboptimal_khr) {
        return error.ImageAcquireFailed;
    }

    std.mem.swap(
        vk.Semaphore,
        &swap_images[result.image_index].image_acquired,
        &next_image_acquired,
    );

    return Swapchain{
        .gc = gc,
        .allocator = allocator,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = actual_extent,
        .handle = handle,
        .swap_images = swap_images,
        .image_index = result.image_index,
        .next_image_acquired = next_image_acquired,
    };
}

fn initSwapchainImages(
    gc: *const GraphicsContext,
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    allocator: Allocator,
) ![]SwapImage {
    var count: u32 = undefined;
    _ = try gc.vkd.getSwapchainImagesKHR(gc.dev, swapchain, &count, null);
    const images = try allocator.alloc(vk.Image, count);
    defer allocator.free(images);
    _ = try gc.vkd.getSwapchainImagesKHR(gc.dev, swapchain, &count, images.ptr);

    const swap_images = try allocator.alloc(SwapImage, count);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format);
        i += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(gc: *const GraphicsContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, null);
    const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    defer allocator.free(surface_formats);
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, surface_formats.ptr);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one.
}

fn findPresentMode(gc: *const GraphicsContext, allocator: Allocator) !vk.PresentModeKHR {
    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, null);
    const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
    defer allocator.free(present_modes);
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, present_modes.ptr);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}
