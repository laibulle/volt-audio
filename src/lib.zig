const std = @import("std");
const builtin = @import("builtin");

// --- Types Publics ---

pub const DeviceInfo = struct {
    id: u32,
    name: []const u8,
    max_input_channels: u32,
    max_output_channels: u32,
    default_sample_rate: f64,
};

pub const Config = struct {
    sample_rate: ?f64 = null,
    buffer_size: ?u32 = null,
    input_channels: u32 = 2,
    output_channels: u32 = 2,
    exclusive_mode: bool = true,
};

pub const AudioCallback = *const fn (input: []const f32, output: []f32, n_samples: u32) void;

// --- Dispatch du Backend ---

pub const VoltAudio = struct {
    const Backend = if (builtin.os.tag == .macos)
        @import("backend/macos_hal.zig")
    else
        @import("backend/asio.zig");

    backend: Backend,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !VoltAudio {
        return .{
            .allocator = allocator,
            .backend = try Backend.init(allocator),
        };
    }

    // ... reste des méthodes (listDevices, openDevice, etc.)
};
