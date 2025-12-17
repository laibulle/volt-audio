# Volt Audio

A high-performance, low-latency audio engine abstraction written in Zig for macOS (CoreAudio). It handles the complexities of hardware communication, channel de-interleaving, and sample normalization, allowing you to focus strictly on digital signal processing (DSP).

## Key Features

- **Automatic De-interleaving**: Handles multi-channel hardware (e.g., Focusrite Scarlett 18i8) by extracting interleaved hardware samples into clean, planar buffers.
- **Sample Normalization**: Guarantees `f32` samples within the `[-1.0, 1.0]` range, regardless of hardware bit-depth.
- **Zero-Allocation Audio Thread**: Uses pre-allocated scratch buffers to ensure real-time safety and prevent audio glitches (XRuns).
- **Hard Clipping Protection**: Automatically clamps output signals to prevent digital wrap-around distortion and protect hardware.

## Getting Started (CLI)

### Prerequisites

- **Zig 0.15.2** or later
- **macOS** (CoreAudio backend)

### Commands

```bash
# Build the project
zig build

# List available audio devices and their IDs
zig build run -- --list

# Start the engine on a specific device (e.g., ID 2) with a 128-frame buffer
zig build run -- --device 2 --buffer 128
```

## Integration as a Zig Library

Volt is designed to be used as a dependency in your own Zig projects.

### 1. Configure build.zig.zon

Add Volt to your dependencies:

```zig
.{
    .name = "my_audio_app",
    .version = "0.1.0",
    .dependencies = .{
        .volt = .{
            .path = "../volt-audio", 
        },
    },
}
```

### 2. Add Module to build.zig

Expose the Volt module to your executable:

```zig
const volt_dep = b.dependency("volt", .{});
const volt_mod = volt_dep.module("volt");
exe.root_module.addImport("volt", volt_mod);
```

### 3. Implement the DSP Callback

The core of your application is the AudioCallback. You receive input and output samples as slices:

```zig
const volt = @import("volt");

fn myDspPlugin(input: []const f32, output: []f32, n_samples: u32) void {
    // Process audio frame
    for (0..n_samples) |i| {
        // Apply a simple volume gain
        const processed = input[i] * 0.75;
        output[i] = processed;
    }
}
```

### 4. Initialize and Start

```zig
var engine = try volt.VoltAudio.init(allocator);

const config = volt.Config{
    .sample_rate = 48000,
    .buffer_size = 256,
};

// Initialize device and start audio
try engine.openDevice(selected_device_id, config, myDspPlugin);
try engine.start();
```
