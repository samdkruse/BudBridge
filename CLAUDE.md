# CLAUDE.md

## Project Overview

BudBridge streams audio bidirectionally between a Windows 11 PC and an iOS device, enabling users to use AirPods connected to their iPhone as PC audio I/O. This works around Bluetooth restrictions that prevent direct AirPods-to-PC connections.

## Architecture

- **iOS App** (`AirpodPcAudio/`): SwiftUI app that receives PC audio and captures AirPods mic
- **Windows App** (`windows/`): Rust GUI application with loopback capture and audio playback

### Audio Flow

```
PC Audio (YouTube, games, etc.)
    ↓ WASAPI Loopback Capture
    ↓ UDP over WiFi
    ↓ iPhone receives
    ↓ AirPods speakers ✓

AirPods mic
    ↓ iPhone captures
    ↓ UDP over WiFi
    ↓ PC receives
    ↓ Virtual audio cable (optional) → Discord/Zoom
```

## Audio Format

Both sides use the same wire format for network transmission:

| Parameter | Value |
|-----------|-------|
| Sample Rate | 48,000 Hz |
| Bit Depth | 16-bit signed PCM |
| Channels | Mono |
| Byte Order | Little-endian |

### Why 48kHz?
- Native sample rate for both Windows and iOS (no resampling needed)
- Bandwidth: ~96 KB/s (negligible for WiFi)

### Windows Side
- **PC → iPhone**: Uses WASAPI loopback to capture system audio from any output device
- **iPhone → PC**: Plays received audio to selected output device (use virtual cable for mic)
- Latency optimizations: 4-packet channel buffers, 50ms max output buffer, VecDeque for O(1) operations

### iOS Side
- **Receiving (PC audio)**: Expects 48kHz 16-bit PCM, converts to Float32 for AVAudioPlayerNode
- **Sending (mic)**: Captures at device rate (often 24kHz with Bluetooth HFP), resamples to 48kHz
- Uses vDSP (hardware accelerated) for resampling and audio conversion
- Jitter buffer (100ms max) with 20ms chunks for smooth playback
- Send buffer with 20ms timer for smooth transmission (prevents bursty packets)
- 5ms IO buffer duration for low latency

## Setup

### PC Audio → iPhone (no extra software needed)
1. Select your speakers with "(Loopback)" in the "PC Audio → iPhone" dropdown
2. Connect to your iPhone
3. Done - PC audio plays through AirPods

### iPhone Mic → PC Apps (requires virtual audio cable)
To use AirPods mic in Discord/Zoom, you need a virtual audio device:
1. Install [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) (free)
2. In BudBridge, set "iPhone → PC" to "CABLE Input"
3. In Discord/Zoom, set microphone to "CABLE Output"

**Why?** Windows doesn't provide an API to create virtual audio devices. This requires a kernel-mode driver, which VB-Audio provides.

## Development Environment

### Windows/Rust (developed in WSL Ubuntu)

Cross-compile for Windows from WSL using mingw:

```bash
cd windows

# Install cross-compilation toolchain (first time)
rustup target add x86_64-pc-windows-gnu
sudo apt install mingw-w64

# Build for Windows
cargo build --release --target x86_64-pc-windows-gnu
```

The output binary will be at `target/x86_64-pc-windows-gnu/release/airpod-pc-audio.exe`

### iOS App

Open `AirpodPcAudio.xcodeproj` in Xcode on macOS. Build and run on device or simulator.

## Key Dependencies

### Windows (Rust)
- `eframe` - Cross-platform GUI framework (egui)
- `cpal` - Cross-platform audio I/O
- `crossbeam-channel` - Multi-producer multi-consumer channels
- `parking_lot` - Fast synchronization primitives
- `anyhow` - Error handling

### iOS (Swift)
- SwiftUI for UI (tabbed interface with PC management)
- AVFoundation for audio playback and mic capture
- Accelerate (vDSP) for resampling, level metering, and PCM conversion
- Network framework for UDP connectivity

## Agent Commands

### "windows deploy"
Build and copy the Windows exe and config folder to the Downloads folder:
```bash
cd /home/samdk/code/BudBridge/windows && \
. "$HOME/.cargo/env" && \
cargo build --release --target x86_64-pc-windows-gnu && \
cp target/x86_64-pc-windows-gnu/release/airpod-pc-audio.exe /mnt/c/Users/samdk/Downloads/ && \
cp -rn budbridgeconfig /mnt/c/Users/samdk/Downloads/
```
Note: `cp -rn` won't overwrite existing config files, preserving user settings.

## Testing

### Adding the Test Target (one-time setup)

1. Open `AirpodPcAudio.xcodeproj` in Xcode
2. File → New → Target → iOS Unit Testing Bundle
3. Name it `AirpodPcAudioTests`
4. Add existing test files from `AirpodPcAudioTests/` folder to the target
5. Add `AudioConversion.swift` to the main app target

### Running Tests

```bash
# From Xcode: Cmd+U to run all tests
# Or: Product → Test
```

### What's Tested

- **AudioConversion**: PCM↔Float conversion, RMS calculation, clipping behavior
- **NetworkPackets**: UDP chunking logic, MTU compliance
- **State Management**: Route change handling, initial states

### What Requires Manual Testing

- Actual audio playback (requires hardware)
- Bluetooth/AirPods connection
- Network connectivity between devices

## Project Structure

```
BudBridge/
├── AirpodPcAudio/           # iOS app source
│   ├── AirpodPcAudioApp.swift
│   ├── ContentView.swift    # Tabbed UI (Connect + PCs tabs)
│   ├── PCsView.swift        # PC management UI
│   ├── PCStore.swift        # Saved PCs model and persistence
│   ├── NetworkManager.swift
│   ├── NetworkUtils.swift   # iPhone IP address detection
│   ├── AudioManager.swift   # Audio capture, playback, resampling
│   └── AudioConversion.swift  # Testable pure functions
├── AirpodPcAudioTests/      # Unit tests
│   ├── AudioConversionTests.swift
│   └── AudioManagerStateTests.swift
├── AirpodPcAudio.xcodeproj/ # Xcode project
├── windows/                  # Windows Rust app
│   ├── .cargo/config.toml   # Cross-compilation config
│   ├── Cargo.toml
│   ├── src/main.rs
│   └── budbridgeconfig/     # Config template (copied on deploy)
│       ├── devices.txt      # Saved devices (name|ip per line)
│       ├── default.txt      # Default device name
│       ├── settings.txt     # App settings (debug=true/false)
│       └── logs/            # Debug logs (when enabled)
└── airpod-pc-audio.exe      # Pre-built Windows binary
```
