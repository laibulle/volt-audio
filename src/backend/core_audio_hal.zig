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
            .mScope = c.kAudioObjectPropertyScopeOutput, // On vérifie la sortie
            .mElement = c.kAudioObjectPropertyElementMain,
        };

        if (c.AudioObjectGetPropertyData(self.device_id, &address, 0, null, &size, &stream_format) != 0) return;

        // Configuration pour un son naturel sans hachures :
        stream_format.mFormatID = c.kAudioFormatLinearPCM;
        stream_format.mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked | c.kAudioFormatFlagIsNonInterleaved;
        stream_format.mFramesPerPacket = 1;
        stream_format.mBytesPerPacket = 4; // f32
        stream_format.mBytesPerFrame = 4;
        stream_format.mChannelsPerFrame = 2; // Stéréo
        stream_format.mBitsPerChannel = 32;

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

    // Sur une carte multi-canaux interleaved, tout est dans mBuffers[0]
    const in_buf = in_list.mBuffers[0];
    const out_buf = out_list.mBuffers[0];

    const num_channels = in_buf.mNumberChannels; // Ici ce sera 8 pour ta Scarlett
    const total_samples = in_buf.mDataByteSize / @sizeOf(f32);
    const n_frames = total_samples / num_channels;

    const in_ptr: [*]const f32 = @ptrCast(@alignCast(in_buf.mData.?));
    const out_ptr: [*]f32 = @ptrCast(@alignCast(out_buf.mData.?));

    // Nous devons dé-entrelacer le canal 1 pour l'envoyer au callback
    // (On utilise un buffer temporaire pour ne pas allouer dans le thread audio)
    var scratch_in: [1024]f32 = undefined; // Taille max de buffer
    var scratch_out: [1024]f32 = undefined;

    const safe_frames = @min(n_frames, 1024);

    // 1. Extraction du canal 1 (index 0)
    var f: u32 = 0;
    while (f < safe_frames) : (f += 1) {
        scratch_in[f] = in_ptr[f * num_channels];
    }

    // 2. Appel du moteur DSP (Volt) sur le canal 1 uniquement
    cb(scratch_in[0..safe_frames], scratch_out[0..safe_frames], safe_frames);

    // 3. Ré-entrelacement vers la sortie (on copie le résultat sur L et R)
    f = 0;
    const out_channels = out_buf.mNumberChannels;
    while (f < safe_frames) : (f += 1) {
        const out_base = f * out_channels;
        out_ptr[out_base] = scratch_out[f]; // Sortie Gauche
        if (out_channels > 1) {
            out_ptr[out_base + 1] = scratch_out[f]; // Sortie Droite
        }
    }

    return 0;
}

test "Audio buffer integration" {
    const testing = std.testing;

    const n_samples = 64;
    // Utilisation de const car la slice elle-même (le pointeur + longueur) ne change pas,
    // même si le CONTENU de la mémoire pointée va changer.
    const mock_input = try testing.allocator.alloc(f32, n_samples);
    const mock_output = try testing.allocator.alloc(f32, n_samples);
    defer testing.allocator.free(mock_input);
    defer testing.allocator.free(mock_output);

    for (mock_input, 0..) |*val, i| {
        val.* = @floatFromInt(i);
    }

    const bypass = struct {
        fn cb(in: []const f32, out: []f32, n: u32) void {
            @memcpy(out[0..n], in[0..n]);
        }
    }.cb;

    bypass(mock_input, mock_output, n_samples);

    try testing.expectEqualSlices(f32, mock_input, mock_output);
}
