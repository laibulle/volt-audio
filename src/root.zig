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
    const Backend = @import("backend/core_audio_hal.zig").CoreAudioHAL;

    backend: Backend,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !VoltAudio {
        return .{
            .allocator = allocator,
            .backend = try Backend.init(allocator),
        };
    }

    pub fn listDevices(self: *VoltAudio) ![]DeviceInfo {
        return self.backend.listDevices();
    }

    pub fn deinitDevices(self: *VoltAudio, devices: []DeviceInfo) void {
        for (devices) |device| {
            self.allocator.free(device.name);
        }
        self.allocator.free(devices);
    }

    pub fn openDevice(self: *VoltAudio, id: u32, config: Config, callback: AudioCallback) !void {
        return self.backend.open(id, config, callback);
    }

    pub fn start(self: *VoltAudio) !void {
        return self.backend.start();
    }
};
