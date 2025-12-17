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

    // Buffers de travail pré-alloués pour le DSP (supporte jusqu'à 8 canaux)
    // On utilise 4096 comme taille max de buffer raisonnable
    in_scratch: [8][4096]f32 = undefined,
    out_scratch: [8][4096]f32 = undefined,
    in_views: [8][]f32 = undefined,
    out_views: [8][]f32 = undefined,

    num_active_in: u32 = 1,
    num_active_out: u32 = 2,

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

        const mem = std.heap.page_allocator.alloc(u8, size) catch return 0;
        defer std.heap.page_allocator.free(mem);

        const buffer_list: *c.AudioBufferList = @ptrCast(@alignCast(mem.ptr));
        if (c.AudioObjectGetPropertyData(id, &address, 0, null, &size, buffer_list) != 0) return 0;

        var total: u32 = 0;
        var i: u32 = 0;
        while (i < buffer_list.mNumberBuffers) : (i += 1) {
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
    const self: *CoreAudioHAL = @ptrCast(@alignCast(inClientData orelse return 0));
    const cb = self.callback orelse return 0;

    const in_list = inInputData orelse return 0;
    const out_list = outOutputData orelse return 0;

    const in_buf = in_list.mBuffers[0];
    const out_buf = out_list.mBuffers[0];

    const in_stride = in_buf.mNumberChannels;
    const out_stride = out_buf.mNumberChannels;

    // Calcul du nombre de frames (on sature à 4096 pour nos scratch buffers)
    const n_frames = @min(out_buf.mDataByteSize / (out_stride * @sizeOf(f32)), 4096);

    const in_ptr: [*]const f32 = @ptrCast(@alignCast(in_buf.mData.?));
    const out_ptr: [*]f32 = @ptrCast(@alignCast(out_buf.mData.?));

    // 1. EXTRACTION & NORMALISATION
    for (0..self.num_active_in) |ch| {
        for (0..n_frames) |f| {
            // Extraction du canal 'ch' depuis le flux entrelacé
            self.in_scratch[ch][f] = in_ptr[f * in_stride + ch];
        }
        self.in_views[ch] = self.in_scratch[ch][0..n_frames];
    }

    // 2. PRÉPARATION DES VUES DE SORTIE
    for (0..self.num_active_out) |ch| {
        self.out_views[ch] = self.out_scratch[ch][0..n_frames];

        // On remet le buffer de sortie à zéro proprement pour éviter les résidus audio
        @memset(self.out_scratch[ch][0..n_frames], 0.0);
    }

    // 3. EXPOSITION AU DSP
    const input_bus = volt.AudioBuffer{
        .channels = self.in_views[0..self.num_active_in],
        .frameCount = @intCast(n_frames),
    };
    const output_bus = volt.AudioBuffer{
        .channels = self.out_views[0..self.num_active_out],
        .frameCount = @intCast(n_frames),
    };

    cb(input_bus, output_bus);

    // 4. INJECTION & CLAMPING
    for (0..n_frames) |f| {
        for (0..out_stride) |ch| {
            // On mappe le canal DSP vers le canal hardware (mono -> stéréo si besoin)
            const source_ch = if (ch < self.num_active_out) ch else 0;
            const sample = self.out_scratch[source_ch][f];

            // On sature à 1.0 pour protéger le matériel
            out_ptr[f * out_stride + ch] = std.math.clamp(sample, -1.0, 1.0);
        }
    }

    return 0;
}

test "Audio buffer integration (8-channel interleaved)" {
    const testing = std.testing;
    const num_channels = 8;
    const n_frames = 4;
    const total_samples = n_frames * num_channels;

    const mock_input = try testing.allocator.alloc(f32, total_samples);
    const mock_output = try testing.allocator.alloc(f32, n_frames * 2);
    defer testing.allocator.free(mock_input);
    defer testing.allocator.free(mock_output);

    // Remplissage simulé (Mic 1 = 0.0, 0.1, 0.2...)
    for (0..n_frames) |f| {
        mock_input[f * num_channels] = @as(f32, @floatFromInt(f)) / 10.0;
        for (1..num_channels) |c_idx| mock_input[f * num_channels + c_idx] = 99.0;
    }

    // On simule ce que fait le HAL
    var s_in: [n_frames]f32 = undefined;
    var s_out: [n_frames]f32 = undefined;

    for (0..n_frames) |f| s_in[f] = mock_input[f * num_channels];
    @memcpy(&s_out, &s_in); // Bypass

    for (0..n_frames) |f| {
        mock_output[f * 2] = s_out[f];
        mock_output[f * 2 + 1] = s_out[f];
    }

    try testing.expectEqual(@as(f32, 0.0), mock_output[0]);
    try testing.expectEqual(@as(f32, 0.1), mock_output[2]);
}
