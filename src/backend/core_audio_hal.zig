const std = @import("std");
const c = @cImport({
    @cInclude("CoreAudio/CoreAudio.h");
});
const volt = @import("../lib.zig");
const DeviceInfo = volt.DeviceInfo;
const Config = volt.Config;

pub const MacOSHAL = struct {
    device_id: c.AudioObjectID,
    is_running: bool = false,
    proc_id: c.AudioDeviceIOProcID = null,
    callback: *const fn (input: []const f32, output: []f32, n_samples: u32) void,

    pub fn init(callback: anytype) !MacOSHAL {
        var device_id: c.AudioObjectID = 0;
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioHardwarePropertyDefaultOutputDevice,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain, // Ancien master
        };

        var size: u32 = @sizeOf(c.AudioObjectID);
        const status = c.AudioObjectGetPropertyData(
            c.kAudioObjectSystemObject,
            &address,
            0,
            null,
            &size,
            &device_id,
        );

        if (status != 0) return error.DeviceNotFound;

        return .{
            .device_id = device_id,
            .callback = callback,
        };
    }

    pub fn start(self: *MacOSHAL) !void {
        const status = c.AudioDeviceCreateIOProcID(
            self.device_id,
            audioIOProc,
            self, // On passe l'instance pour la récupérer dans le callback
            &self.proc_id,
        );
        if (status != 0) return error.ProcCreationFailed;

        _ = c.AudioDeviceStart(self.device_id, self.proc_id);
        self.is_running = true;
    }

    pub fn listDevices(self: *MacOSHAL) ![]DeviceInfo {
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioHardwarePropertyDevices,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        var size: u32 = 0;
        _ = c.AudioObjectGetPropertyDataSize(c.kAudioObjectSystemObject, &address, 0, null, &size);

        const count = size / @sizeOf(c.AudioObjectID);
        const ids = try self.allocator.alloc(c.AudioObjectID, count);
        defer self.allocator.free(ids);

        _ = c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &address, 0, null, &size, ids.ptr);

        var devices = try self.allocator.alloc(DeviceInfo, count);
        for (ids, 0..) |id, i| {
            devices[i] = try self.getDeviceInfo(id);
        }
        return devices;
    }

    fn getDeviceInfo(self: *MacOSHAL, id: c.AudioObjectID) !DeviceInfo {
        // var _name: [256]u8 = undefined;
        // var _size: u32 = 256;
        // var _address = c.AudioObjectPropertyAddress{
        //     .mSelector = c.kAudioDevicePropertyDeviceNameCFString,
        //     .mScope = c.kAudioObjectPropertyScopeGlobal,
        //     .mElement = c.kAudioObjectPropertyElementMain,
        // };

        // Note: En vrai, Core Audio renvoie un CFStringRef,
        // il faut le convertir en UTF-8 pour Zig.
        // ... code de conversion CFString -> slice Zig ...

        return DeviceInfo{
            .id = id,
            .name = "Nom du device",
            .max_input_channels = self.getChannelCount(id, .input),
            .max_output_channels = self.getChannelCount(id, .output),
            .default_sample_rate = self.getSampleRate(id),
        };
    }

    pub fn open(self: *MacOSHAL, device_id: c.AudioObjectID, config: Config) !void {
        self.device_id = device_id;

        // 1. Appliquer le Sample Rate si spécifié
        if (config.sample_rate) |rate| {
            try self.setSampleRate(rate);
        }

        // 2. Appliquer la taille de buffer (La latence !)
        if (config.buffer_size) |size| {
            try self.setBufferSize(size);
        }

        // 3. Vérifier que le format est bien en Float32 (Standard Volt-Audio)
        try self.verifyStreamFormat();
    }
};

fn audioIOProc(
    inDevice: c.AudioObjectID,
    inNow: ?*const c.AudioTimeStamp,
    inInputData: ?*const c.AudioBufferList,
    inInputTime: ?*const c.AudioTimeStamp,
    outOutputData: ?*c.AudioBufferList,
    inOutputTime: ?*const c.AudioTimeStamp,
    inClientData: ?*anyopaque,
) callconv(.C) c.OSStatus {
    _ = inDevice;
    _ = inNow;
    _ = inInputTime;
    _ = inOutputTime;

    const self: *MacOSHAL = @ptrCast(@alignCast(inClientData));

    // 1. Extraire les buffers (simplifié pour 1 canal ici)
    const in_buffer = inInputData.?.mBuffers[0];
    const out_buffer = outOutputData.?.mBuffers[0];

    const n_samples = out_buffer.mDataByteSize / @sizeOf(f32);

    const input_slice: []f32 = @as([*]f32, @ptrCast(in_buffer.mData.?))[0..n_samples];
    const output_slice: []f32 = @as([*]f32, @ptrCast(out_buffer.mData.?))[0..n_samples];

    // 2. Appeler ton moteur DSP (Volt-Audio)
    self.callback(input_slice, output_slice, n_samples);

    return 0;
}

pub fn setBufferSize(device_id: c.AudioObjectID, size: u32) !void {
    var buffer_size = size;
    const property_size = @sizeOf(u32);
    var address = c.AudioObjectPropertyAddress{
        .mSelector = c.kAudioDevicePropertyBufferFrameSize,
        .mScope = c.kAudioObjectPropertyScopeGlobal,
        .mElement = c.kAudioObjectPropertyElementMain,
    };

    const status = c.AudioObjectSetPropertyData(
        device_id,
        &address,
        0,
        null,
        property_size,
        &buffer_size,
    );

    if (status != 0) return error.CannotSetBufferSize;
}
