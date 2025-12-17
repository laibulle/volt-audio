const std = @import("std");
const c = @cImport({
    @cInclude("CoreAudio/CoreAudio.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});
const volt = @import("../root.zig");
const DeviceInfo = volt.DeviceInfo;
const Config = volt.Config;

pub const CoreAudioHAL = struct {
    allocator: std.mem.Allocator,
    device_id: c.AudioObjectID = 0,
    is_running: bool = false,
    proc_id: c.AudioDeviceIOProcID = null,
    callback: ?volt.AudioCallback = null,

    pub fn init(allocator: std.mem.Allocator) !CoreAudioHAL {
        return CoreAudioHAL{
            .allocator = allocator,
        };
    }

    pub fn listDevices(self: *CoreAudioHAL) ![]DeviceInfo {
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

    fn getDeviceInfo(self: *CoreAudioHAL, id: c.AudioObjectID) !DeviceInfo {
        return DeviceInfo{
            .id = id,
            .name = try self.getDeviceName(id),
            .max_input_channels = self.getChannelCount(id, c.kAudioObjectPropertyScopeInput),
            .max_output_channels = self.getChannelCount(id, c.kAudioObjectPropertyScopeOutput),
            .default_sample_rate = self.getSampleRate(id),
        };
    }

    fn getDeviceName(self: *CoreAudioHAL, id: c.AudioObjectID) ![]const u8 {
        var cf_name: c.CFStringRef = undefined;
        var size: u32 = @sizeOf(c.CFStringRef);
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyDeviceNameCFString,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        if (c.AudioObjectGetPropertyData(id, &address, 0, null, &size, @ptrCast(&cf_name)) != 0) {
            return try self.allocator.dupe(u8, "Unknown Device");
        }
        defer c.CFRelease(cf_name);

        const length = c.CFStringGetLength(cf_name);
        const max_size = c.CFStringGetMaximumSizeForEncoding(length, c.kCFStringEncodingUTF8) + 1;
        const buffer = try self.allocator.alloc(u8, @intCast(max_size));
        defer self.allocator.free(buffer);

        if (c.CFStringGetCString(cf_name, buffer.ptr, @intCast(max_size), c.kCFStringEncodingUTF8) == 0) {
            return try self.allocator.dupe(u8, "Encoding Error");
        }

        return try self.allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(buffer.ptr))));
    }

    fn getChannelCount(_: *CoreAudioHAL, id: c.AudioObjectID, scope: c.AudioObjectPropertyScope) u32 {
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyStreamConfiguration,
            .mScope = scope,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        var size: u32 = 0;
        if (c.AudioObjectGetPropertyDataSize(id, &address, 0, null, &size) != 0) return 0;

        // Pour un test simple, on simule 2 canaux.
        // L'implémentation réelle nécessite de parser la AudioBufferList
        return 2;
    }

    fn getSampleRate(_: *CoreAudioHAL, id: c.AudioObjectID) f64 {
        var rate: f64 = 0;
        var size: u32 = @sizeOf(f64);
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyNominalSampleRate,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        if (c.AudioObjectGetPropertyData(id, &address, 0, null, &size, &rate) != 0) return 44100.0;
        return rate;
    }

    pub fn open(self: *CoreAudioHAL, device_id: c.AudioObjectID, config: Config, callback: volt.AudioCallback) !void {
        self.device_id = device_id;
        self.callback = callback;

        if (config.sample_rate) |rate| {
            try self.setSampleRate(rate);
        }
        if (config.buffer_size) |size| {
            try self.setBufferSize(size);
        }
        try self.verifyStreamFormat();
    }

    pub fn start(self: *CoreAudioHAL) !void {
        const status = c.AudioDeviceCreateIOProcID(
            self.device_id,
            audioIOProc,
            self,
            &self.proc_id,
        );
        if (status != 0) return error.ProcCreationFailed;

        _ = c.AudioDeviceStart(self.device_id, self.proc_id);
        self.is_running = true;
    }

    fn setSampleRate(self: *CoreAudioHAL, rate: f64) !void {
        var r = rate;
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyNominalSampleRate,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };
        _ = c.AudioObjectSetPropertyData(self.device_id, &address, 0, null, @sizeOf(f64), &r);
    }

    fn setBufferSize(self: *CoreAudioHAL, size: u32) !void {
        var s = size;
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyBufferFrameSize,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };
        _ = c.AudioObjectSetPropertyData(self.device_id, &address, 0, null, @sizeOf(u32), &s);
    }

    fn verifyStreamFormat(self: *CoreAudioHAL) !void {
        var stream_format: c.AudioStreamBasicDescription = undefined;
        var size: u32 = @sizeOf(c.AudioStreamBasicDescription);
        var address = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioDevicePropertyStreamFormat,
            .mScope = c.kAudioObjectPropertyScopeOutput,
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        _ = c.AudioObjectGetPropertyData(self.device_id, &address, 0, null, &size, &stream_format);

        stream_format.mFormatID = c.kAudioFormatLinearPCM;
        stream_format.mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked;

        _ = c.AudioObjectSetPropertyData(self.device_id, &address, 0, null, size, &stream_format);
    }
};

fn audioIOProc(
    _: c.AudioObjectID,
    _: ?*const c.AudioTimeStamp,
    inInputData: ?*const c.AudioBufferList,
    _: ?*const c.AudioTimeStamp,
    outOutputData: ?*c.AudioBufferList,
    _: ?*const c.AudioTimeStamp,
    inClientData: ?*anyopaque,
) callconv(.c) c.OSStatus {
    const self: *CoreAudioHAL = @ptrCast(@alignCast(inClientData));
    const cb = self.callback orelse return 0;

    // Protection contre les buffers nulls
    const in_list = inInputData orelse return 0;
    const out_list = outOutputData orelse return 0;

    const in_buf = in_list.mBuffers[0];
    const out_buf = out_list.mBuffers[0];

    const n_samples: u32 = @intCast(out_buf.mDataByteSize / @sizeOf(f32));

    // Utilisation de @alignCast car mData est un *anyopaque (alignement 1)
    // alors que f32 nécessite un alignement de 4.
    const input_ptr: [*]f32 = @ptrCast(@alignCast(in_buf.mData.?));
    const output_ptr: [*]f32 = @ptrCast(@alignCast(out_buf.mData.?));

    cb(input_ptr[0..n_samples], output_ptr[0..n_samples], n_samples);

    return 0;
}
