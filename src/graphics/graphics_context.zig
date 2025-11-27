const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;

const GetInstanceProc = *const fn (
    vk.Instance,
    [*:0]const u8,
) callconv(.c) vk.PfnVoidFunction;

const GetDeviceProc = *const fn (
    vk.Device,
    [*:0]const u8,
) callconv(.c) vk.PfnVoidFunction;

// Required Vulkan device extensions (C strings, NUL-terminated).
const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};

const optional_device_extensions = [_][*:0]const u8{};

// Optional *instance* extensions we try to enable if present.
const optional_instance_extensions = [_][*:0]const u8{
    vk.extensions.khr_get_physical_device_properties_2.name,
};

// Modern vulkan-zig: wrappers are already monomorphized types.
// No more vk.BaseWrapper(apis) – we just alias the types.
const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;

pub const GraphicsContext = struct {
    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: vk.Device,
    graphics_queue: Queue,
    present_queue: Queue,

    pub fn init(
        allocator: Allocator,
        app_name: [*:0]const u8,
        window: *glfw.Window,
    ) !GraphicsContext {
        var self: GraphicsContext = undefined;

        // ── Base dispatch: use a shim that adapts glfw-zig's loader
        //    to vulkan-zig's expected signature.
        const get_proc: GetInstanceProc = glfwGetInstanceProc;
        self.vkb = BaseDispatch.load(get_proc);

        // ─────────────────────────────────────────────────────────────
        // Instance extensions via GLFW (this part stays as you have it)
        // ─────────────────────────────────────────────────────────────

        const glfw_exts_opt = glfw.getRequiredInstanceExtensions(allocator) catch |err| {
            if (glfw.getLastError()) |err_info| {
                const code_opt = glfw.errorCodeFromC(err_info.code);
                const code_str = if (code_opt) |ce| @tagName(ce) else "UnknownError";

                const desc_str: []const u8 = err_info.description orelse "no description";
                std.log.err(
                    "failed to get required Vulkan instance extensions via GLFW: {s}: {s}",
                    .{ code_str, desc_str },
                );
            } else {
                std.log.err(
                    "failed to get required Vulkan instance extensions via GLFW (no error info): {s}",
                    .{@errorName(err)},
                );
            }
            return error.VulkanInstanceExtensionsQueryFailed;
        };

        const glfw_exts = glfw_exts_opt orelse {
            std.log.err("GLFW reported no required Vulkan instance extensions", .{});
            return error.VulkanInstanceExtensionsMissing;
        };

        var instance_extensions = try std.ArrayList([*:0]const u8).initCapacity(
            allocator,
            glfw_exts.len + optional_instance_extensions.len,
        );
        defer instance_extensions.deinit(allocator);

        for (glfw_exts) |ext_name_z| {
            try instance_extensions.append(allocator, ext_name_z.ptr);
        }

        var count: u32 = 0;
        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &count, null);

        const propsv = try allocator.alloc(vk.ExtensionProperties, count);
        defer allocator.free(propsv);

        _ = try self.vkb.enumerateInstanceExtensionProperties(null, &count, propsv.ptr);

        for (optional_instance_extensions) |ext_name| {
            const ext_span = std.mem.span(ext_name);

            for (propsv) |prop| {
                const name_len =
                    std.mem.indexOfScalar(u8, &prop.extension_name, 0) orelse prop.extension_name.len;
                const prop_name = prop.extension_name[0..name_len];

                if (std.mem.eql(u8, prop_name, ext_span)) {
                    try instance_extensions.append(allocator, ext_name);
                    break;
                }
            }
        }

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = app_name,
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.makeApiVersion(0, 1, 1, 0)),
        };

        const enabled_ext_count: u32 = @intCast(instance_extensions.items.len);
        const enabled_ext_ptr: [*]const [*:0]const u8 =
            @ptrCast(instance_extensions.items.ptr);

        self.instance = try self.vkb.createInstance(&vk.InstanceCreateInfo{
            .flags = if (builtin.os.tag == .macos)
                .{ .enumerate_portability_bit_khr = true }
            else
                .{},
            .p_application_info = &app_info,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = undefined,
            .enabled_extension_count = enabled_ext_count,
            .pp_enabled_extension_names = enabled_ext_ptr,
        }, null);

        // ── Instance dispatch: unwrap the optional vkGetInstanceProcAddr
        const get_inst_proc: GetInstanceProc = self.vkb.dispatch.vkGetInstanceProcAddr.?;
        self.vki = InstanceDispatch.load(self.instance, get_inst_proc);
        errdefer self.vki.destroyInstance(self.instance, null);

        self.surface = try createSurface(self.instance, window);
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

        const candidate = try pickPhysicalDevice(self.vki, self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;

        self.dev = try initializeCandidate(allocator, self.vki, candidate);

        const get_dev_proc: GetDeviceProc = self.vki.dispatch.vkGetDeviceProcAddr.?;
        self.vkd = DeviceDispatch.load(self.dev, get_dev_proc);

        errdefer self.vkd.destroyDevice(self.dev, null);

        self.graphics_queue = Queue.init(self.vkd, self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.vkd, self.dev, candidate.queues.present_family);

        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);

        return self;
    }

    pub fn deinit(self: GraphicsContext) void {
        self.vkd.destroyDevice(self.dev, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }

    pub fn deviceName(self: GraphicsContext) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.props.device_name, 0).?;
        return self.props.device_name[0..len];
    }

    pub fn findMemoryTypeIndex(
        self: GraphicsContext,
        memory_type_bits: u32,
        flags: vk.MemoryPropertyFlags,
    ) !u32 {
        for (
            self.mem_props.memory_types[0..self.mem_props.memory_type_count],
            0..,
        ) |mem_type, i| {
            const idx_u5: u5 = @truncate(i);
            const bit: u32 = @as(u32, 1) << idx_u5;

            if (memory_type_bits & bit != 0 and mem_type.property_flags.contains(flags)) {
                return @as(u32, @truncate(i));
            }
        }

        return error.NoSuitableMemoryType;
    }

    pub fn allocate(
        self: GraphicsContext,
        requirements: vk.MemoryRequirements,
        flags: vk.MemoryPropertyFlags,
    ) !vk.DeviceMemory {
        return try self.vkd.allocateMemory(self.dev, &.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(
                requirements.memory_type_bits,
                flags,
            ),
        }, null);
    }
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: DeviceDispatch, dev: vk.Device, family: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};

fn glfwGetInstanceProc(
    instance: vk.Instance,
    name: [*:0]const u8,
) callconv(.c) vk.PfnVoidFunction {
    // vk.Instance is enum(usize). Go via its integer payload.
    const opaque_instance: ?*anyopaque = @ptrFromInt(@intFromEnum(instance));

    // Convert [*:0]const u8 → [:0]const u8 for glfw-zig.
    const name_slice: [:0]const u8 = std.mem.span(name);

    // glfw-zig returns an optional raw function pointer.
    const raw = glfw.getInstanceProcAddress(opaque_instance, name_slice);

    if (raw) |p| {
        return @ptrCast(p);
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Surface creation (GLFW → VkSurfaceKHR)
// ─────────────────────────────────────────────────────────────────────────────

extern fn glfwCreateWindowSurface(
    instance: vk.Instance,
    window: *glfw.Window,
    allocator: ?*const anyopaque,
    surface: *vk.SurfaceKHR,
) vk.Result;

fn createSurface(instance: vk.Instance, window: *glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;

    const res: vk.Result = glfwCreateWindowSurface(
        instance,
        window,
        null,
        &surface,
    );

    if (res != .success) return error.SurfaceInitFailed;
    return surface;
}

// ─────────────────────────────────────────────────────────────────────────────
// Device selection, queue allocation, extension checks
// ─────────────────────────────────────────────────────────────────────────────

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(
    vki: InstanceDispatch,
    instance: vk.Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    var device_count: u32 = 0;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(pdevs);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, pdevs.ptr);

    for (pdevs) |pdev| {
        if (try checkSuitable(vki, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    vki: InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    const props = vki.getPhysicalDeviceProperties(pdev);

    if (!try checkExtensionSupport(vki, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(vki, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(vki, pdev, allocator, surface)) |allocation| {
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(
    vki: InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?QueueAllocation {
    var family_count: u32 = 0;
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);

    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null) {
            const support: vk.Bool32 =
                try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface);

            // Bool32 is an enum(i32); treat non-zero as "true".
            if (@intFromEnum(support) != 0) {
                present_family = family;
            }
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(
    vki: InstanceDispatch,
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) !bool {
    var format_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = 0;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(
        pdev,
        surface,
        &present_mode_count,
        null,
    );

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    vki: InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    var count: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, propsv.ptr);

    // Ensure all required_device_extensions are present.
    for (required_device_extensions) |ext_name| {
        const ext_span = std.mem.span(ext_name);
        var found = false;

        for (propsv) |props| {
            const len =
                std.mem.indexOfScalar(u8, &props.extension_name, 0) orelse props.extension_name.len;
            const prop_name = props.extension_name[0..len];
            if (std.mem.eql(u8, prop_name, ext_span)) {
                found = true;
                break;
            }
        }

        if (!found) return false;
    }

    return true;
}

// initializeCandidate stays mostly unchanged, but uses the device_extensions
// ArrayList([*:0]const u8) and passes ptrs to Vulkan in a type-correct way.
fn initializeCandidate(
    allocator: Allocator,
    vki: InstanceDispatch,
    candidate: DeviceCandidate,
) !vk.Device {
    const priority = [_]f32{1.0};

    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1 // NVIDIA
    else
        2; // AMD / split queues

    var device_extensions = try std.ArrayList([*:0]const u8).initCapacity(
        allocator,
        required_device_extensions.len,
    );
    defer device_extensions.deinit(allocator);

    try device_extensions.appendSlice(allocator, required_device_extensions[0..]);

    var count: u32 = 0;
    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try vki.enumerateDeviceExtensionProperties(candidate.pdev, null, &count, propsv.ptr);

    for (optional_device_extensions) |extension_name| {
        const ext_span = std.mem.span(extension_name);

        for (propsv) |prop| {
            const len =
                std.mem.indexOfScalar(u8, &prop.extension_name, 0) orelse prop.extension_name.len;
            const prop_ext_name = prop.extension_name[0..len];

            if (std.mem.eql(u8, prop_ext_name, ext_span)) {
                try device_extensions.append(allocator, extension_name);
                break;
            }
        }
    }

    return try vki.createDevice(candidate.pdev, &.{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @as(u32, @intCast(device_extensions.items.len)),
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(device_extensions.items.ptr)),
        .p_enabled_features = null,
    }, null);
}
