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
        defer allocator.free(devices);

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
        defer allocator.free(devices);

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

        std.debug.print("Démarrage sur {s} avec un buffer de {d} samples...\n", .{ selected.name, buffer_size });

        try engine.openDevice(selected.id, config, audioCallback);
        try engine.start();

        std.debug.print("En lecture... Appuyez sur Ctrl+C pour arrêter.\n", .{});
        while (true) std.time.sleep(std.time.ns_per_s);
    }

    std.debug.print("Usage: volt-run --list  OU  volt-run --device <idx> --buffer <size>\n", .{});
}

// Le callback de test (Direct monitoring)
fn audioCallback(input: []const f32, output: []f32, n_samples: u32) void {
    // On copie l'entrée vers la sortie pour tester la latence "à vide"
    @memcpy(output[0..n_samples], input[0..n_samples]);
}

// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }

// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }
