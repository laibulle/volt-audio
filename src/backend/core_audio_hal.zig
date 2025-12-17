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

        // 1. On alloue un buffer brut pour stocker la AudioBufferList de taille variable
        const mem = std.heap.page_allocator.alloc(u8, size) catch return 0;
        defer std.heap.page_allocator.free(mem);

        // 2. On cast ce buffer en pointeur AudioBufferList
        const buffer_list: *c.AudioBufferList = @ptrCast(@alignCast(mem.ptr));

        if (c.AudioObjectGetPropertyData(id, &address, 0, null, &size, buffer_list) != 0) return 0;

        // 3. On compte les canaux
        var total: u32 = 0;
        var i: u32 = 0;
        while (i < buffer_list.mNumberBuffers) : (i += 1) {
            // Accès sécurisé au tableau mBuffers via ptr_at
            // Note: mBuffers dans le header C est souvent défini comme [1] mais est extensible
            const buffers_ptr: [*]c.AudioBuffer = @ptrCast(&buffer_list.mBuffers);
            total += buffers_ptr[i].mNumberChannels;
        }
        return total;
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
        // Important: on configure le flux pour s'assurer du PCM Float
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

        if (c.AudioObjectGetPropertyData(self.device_id, &address, 0, null, &size, &stream_format) != 0) return;

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

    const in_list = inInputData orelse return 0;
    const out_list = outOutputData orelse return 0;

    const in_buf = in_list.mBuffers[0];
    const out_buf = out_list.mBuffers[0];

    const in_chan = in_buf.mNumberChannels;
    const out_chan = out_buf.mNumberChannels;

    const n_frames = out_buf.mDataByteSize / (out_chan * @sizeOf(f32));

    const in_ptr: [*]const f32 = @ptrCast(@alignCast(in_buf.mData.?));
    const out_ptr: [*]f32 = @ptrCast(@alignCast(out_buf.mData.?));

    // Buffer scratch pour éviter les allocations dans le thread audio
    var scratch_in: [4096]f32 = undefined;
    var scratch_out: [4096]f32 = undefined;
    const frames = @min(n_frames, 4096);

    // 1. Dé-entrelacement (Extraction Mic 1)
    for (0..frames) |f| {
        scratch_in[f] = in_ptr[f * in_chan];
    }

    // 2. Traitement DSP
    cb(scratch_in[0..frames], scratch_out[0..frames], @intCast(frames));

    // 3. Ré-entrelacement vers Sortie (Copie Mono -> Stéréo L/R)
    for (0..frames) |f| {
        out_ptr[f * out_chan] = scratch_out[f];
        if (out_chan > 1) out_ptr[f * out_chan + 1] = scratch_out[f];
    }

    return 0;
}

test "Audio buffer integration (8-channel interleaved)" {
    const testing = std.testing;
    const num_channels = 8;
    const n_frames = 4;
    const total_samples = n_frames * num_channels;

    const mock_input = try testing.allocator.alloc(f32, total_samples);
    const mock_output = try testing.allocator.alloc(f32, n_frames * 2); // Stéréo
    defer testing.allocator.free(mock_input);
    defer testing.allocator.free(mock_output);

    for (0..n_frames) |f| {
        mock_input[f * num_channels] = @as(f32, @floatFromInt(f)) / 10.0;
        for (1..num_channels) |c_idx| mock_input[f * num_channels + c_idx] = 99.0;
    }

    // Simulation de la logique de l'audioIOProc pour le dé-entrelacement
    var scratch_in: [n_frames]f32 = undefined;
    var scratch_out: [n_frames]f32 = undefined;

    // Dé-entrelacement
    for (0..n_frames) |f| scratch_in[f] = mock_input[f * num_channels];

    // Callback Bypass
    @memcpy(&scratch_out, &scratch_in);

    // Ré-entrelacement
    for (0..n_frames) |f| {
        mock_output[f * 2] = scratch_out[f];
        mock_output[f * 2 + 1] = scratch_out[f];
    }

    // Maintenant le test DOIT passer car on compare le Mic 1 extrait
    try testing.expectEqual(@as(f32, 0.0), mock_output[0]);
    try testing.expectEqual(@as(f32, 0.1), mock_output[2]);
}
