const std = @import("std");
const volt = @import("volt_audio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var engine = try volt.VoltAudio.init(allocator);

    // --- Mode Liste ---
    if (args.len > 1 and std.mem.eql(u8, args[1], "--list")) {
        const devices = try engine.listDevices();
        defer engine.deinitDevices(devices);

        std.debug.print("\n--- Périphériques Audio Disponibles ---\n", .{});
        for (devices, 0..) |dev, i| {
            std.debug.print("[{d}] {s} (In: {d}, Out: {d}, Rate: {d}Hz)\n", .{
                i, dev.name, dev.max_input_channels, dev.max_output_channels, dev.default_sample_rate,
            });
        }
        return;
    }

    // --- Mode Run ---
    if (args.len > 1 and std.mem.eql(u8, args[1], "--device")) {
        const device_idx = try std.fmt.parseInt(usize, args[2], 10);
        const devices = try engine.listDevices();
        defer engine.deinitDevices(devices);

        if (device_idx >= devices.len) return error.InvalidDeviceIndex;
        const selected = devices[device_idx];

        // On cherche le flag --buffer, sinon 64 par défaut
        var buffer_size: u32 = 64;
        if (args.len > 4 and std.mem.eql(u8, args[3], "--buffer")) {
            buffer_size = try std.fmt.parseInt(u32, args[4], 10);
        }

        const config = volt.Config{
            .sample_rate = selected.default_sample_rate,
            .buffer_size = buffer_size,
        };

        std.debug.print("Starting audio onur {s} with a buffer of {d} samples...\n", .{ selected.name, buffer_size });

        try engine.openDevice(selected.id, config, audioCallback);
        try engine.start();

        std.debug.print("Playing audio...type CTRL+C to stop\n", .{});
        while (true) {}
    }

    std.debug.print("Usage: volt-run --list  OU  volt-run --device <idx> --buffer <size>\n", .{});
}

// Le callback de test (Direct monitoring)
fn audioCallback(input: volt.AudioBuffer, output: volt.AudioBuffer) void {

    // 1. On récupère le canal 0 (Mic 1 de ta Scarlett)
    // getChannel(0) retourne une slice []f32 déjà dé-entrelacée
    const in_mic1 = input.getChannel(0);

    // 2. On récupère les canaux de sortie (Stéréo L et R)
    const out_L = output.getChannel(0);
    const out_R = output.getChannel(1);

    // 3. Traitement (Bypass Mono vers Stéréo)
    // On utilise frameCount pour savoir combien de samples traiter
    for (0..input.frameCount) |i| {
        const sample = in_mic1[i];

        // On copie le micro 1 sur les deux sorties
        out_L[i] = sample;
        out_R[i] = sample;
    }
}
