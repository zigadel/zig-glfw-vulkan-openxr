const std = @import("std");
const math = std.math;

pub const Mat4 = struct {
    data: [16]f32, // Column-major 4x4 matrix for compatibility with Vulkan

    /// Creates a perspective projection matrix.
    /// - `fov`: Field of view in degrees
    /// - `aspect_ratio`: Width divided by height of the viewport
    /// - `near`: Near clipping plane
    /// - `far`: Far clipping plane
    pub fn perspective(fov: f32, aspect_ratio: f32, near: f32, far: f32) Mat4 {
        const rad = math.radians(fov);
        const tan_half_fov = math.tan(rad / 2.0);

        return Mat4{
            .data = [_]f32{
                1.0 / (aspect_ratio * tan_half_fov), 0,                  0,                                  0,
                0,                                   1.0 / tan_half_fov, 0,                                  0,
                0,                                   0,                  -(far + near) / (far - near),       -1.0,
                0,                                   0,                  -(2.0 * far * near) / (far - near), 0,
            },
        };
    }

    /// Creates an orthographic projection matrix.
    /// - `left`, `right`: Left and right bounds of the view
    /// - `bottom`, `top`: Bottom and top bounds of the view
    /// - `near`: Near clipping plane
    /// - `far`: Far clipping plane
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        return Mat4{
            .data = [_]f32{
                2.0 / (right - left),             0,                                0,                            0,
                0,                                2.0 / (top - bottom),             0,                            0,
                0,                                0,                                -2.0 / (far - near),          0,
                -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1.0,
            },
        };
    }
};

// projection.zig (at the bottom of the file)

test "projection - perspective matrix" {
    const fov = 90.0;
    const aspect_ratio = 1.0;
    const near = 0.1;
    const far = 100.0;
    const perspective_matrix = Mat4.perspective(fov, aspect_ratio, near, far);

    const expected = Mat4{
        .data = [_]f32{
            1.0, 0,   0,                                  0,
            0,   1.0, 0,                                  0,
            0,   0,   -(far + near) / (far - near),       -1.0,
            0,   0,   -(2.0 * far * near) / (far - near), 0,
        },
    };

    try std.testing.expectApproxEqual(f32, perspective_matrix.data[0], expected.data[0], 1e-6);
    try std.testing.expectApproxEqual(f32, perspective_matrix.data[5], expected.data[5], 1e-6);
    try std.testing.expectApproxEqual(f32, perspective_matrix.data[10], expected.data[10], 1e-6);
    try std.testing.expectApproxEqual(f32, perspective_matrix.data[11], expected.data[11], 1e-6);
    try std.testing.expectApproxEqual(f32, perspective_matrix.data[14], expected.data[14], 1e-6);
}

test "projection - orthographic matrix" {
    const left = -1.0;
    const right = 1.0;
    const bottom = -1.0;
    const top = 1.0;
    const near = 0.1;
    const far = 100.0;
    const ortho_matrix = Mat4.orthographic(left, right, bottom, top, near, far);

    const expected = Mat4{
        .data = [_]f32{
            1.0, 0,   0,                            0,
            0,   1.0, 0,                            0,
            0,   0,   -2.0 / (far - near),          0,
            0,   0,   -(far + near) / (far - near), 1.0,
        },
    };

    try std.testing.expectApproxEqual(f32, ortho_matrix.data[0], expected.data[0], 1e-6);
    try std.testing.expectApproxEqual(f32, ortho_matrix.data[5], expected.data[5], 1e-6);
    try std.testing.expectApproxEqual(f32, ortho_matrix.data[10], expected.data[10], 1e-6);
    try std.testing.expectApproxEqual(f32, ortho_matrix.data[14], expected.data[14], 1e-6);
}
