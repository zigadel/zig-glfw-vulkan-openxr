const std = @import("std");
const math = std.math;

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn subtract(a: Vec3, b: Vec3) Vec3 {
        return Vec3{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        return Vec3{ .x = v.x / len, .y = v.y / len, .z = v.z / len };
    }
};

pub const Mat4 = struct {
    data: [16]f32, // 4x4 matrix stored in column-major order

    pub fn identity() Mat4 {
        return Mat4{
            .data = [_]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
        };
    }

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result = Mat4.identity();
        for (0..4) |row| {
            for (0..4) |col| {
                result.data[col * 4 + row] =
                    a.data[0 * 4 + row] * b.data[col * 4 + 0] +
                    a.data[1 * 4 + row] * b.data[col * 4 + 1] +
                    a.data[2 * 4 + row] * b.data[col * 4 + 2] +
                    a.data[3 * 4 + row] * b.data[col * 4 + 3];
            }
        }
        return result;
    }

    pub fn transpose(m: Mat4) Mat4 {
        return Mat4{
            .data = [_]f32{
                m.data[0], m.data[4], m.data[8],  m.data[12],
                m.data[1], m.data[5], m.data[9],  m.data[13],
                m.data[2], m.data[6], m.data[10], m.data[14],
                m.data[3], m.data[7], m.data[11], m.data[15],
            },
        };
    }

    pub fn translation(v: Vec3) Mat4 {
        var mat = Mat4.identity();
        mat.data[12] = v.x;
        mat.data[13] = v.y;
        mat.data[14] = v.z;
        return mat;
    }

    pub fn scaling(v: Vec3) Mat4 {
        return Mat4{
            .data = [_]f32{
                v.x, 0,   0,   0,
                0,   v.y, 0,   0,
                0,   0,   v.z, 0,
                0,   0,   0,   1,
            },
        };
    }

    pub fn rotation(angle: f32, axis: Vec3) Mat4 {
        const rad = math.degreesToRadians(angle);
        const cos = math.cos(rad);
        const sin = math.sin(rad);
        const one_minus_cos = 1.0 - cos;
        const normalized_axis = Vec3.normalize(axis);
        const x = normalized_axis.x;
        const y = normalized_axis.y;
        const z = normalized_axis.z;

        return Mat4{
            .data = [_]f32{
                cos + x * x * one_minus_cos,     x * y * one_minus_cos - z * sin, x * z * one_minus_cos + y * sin, 0,
                y * x * one_minus_cos + z * sin, cos + y * y * one_minus_cos,     y * z * one_minus_cos - x * sin, 0,
                z * x * one_minus_cos - y * sin, z * y * one_minus_cos + x * sin, cos + z * z * one_minus_cos,     0,
                0,                               0,                               0,                               1,
            },
        };
    }
};

test "transform - translation matrix" {
    const tx = 2.0;
    const ty = 3.0;
    const tz = 4.0;
    const translation_matrix = Mat4.translation(Vec3{ .x = tx, .y = ty, .z = tz });

    const expected = Mat4{
        .data = [_]f32{
            1,  0,  0,  0,
            0,  1,  0,  0,
            0,  0,  1,  0,
            tx, ty, tz, 1,
        },
    };

    try std.testing.expectEqual(translation_matrix, expected);
}

// -- Tests --

test "transform - rotation matrix around Y axis" {
    const angle = 90.0;
    const rotation_matrix = Mat4.rotation(angle, Vec3{ .x = 0, .y = 1, .z = 0 });

    const expected = Mat4{
        .data = [_]f32{
            0,  0, 1, 0,
            0,  1, 0, 0,
            -1, 0, 0, 0,
            0,  0, 0, 1,
        },
    };

    try std.testing.expectEqual(rotation_matrix, expected);
}

test "transform - scale matrix" {
    const sx = 2.0;
    const sy = 3.0;
    const sz = 4.0;
    const scale_matrix = Mat4.scaling(Vec3{ .x = sx, .y = sy, .z = sz });

    const expected = Mat4{
        .data = [_]f32{
            sx, 0,  0,  0,
            0,  sy, 0,  0,
            0,  0,  sz, 0,
            0,  0,  0,  1,
        },
    };

    try std.testing.expectEqual(scale_matrix, expected);
}
