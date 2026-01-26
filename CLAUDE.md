# CLAUDE.md

## Project Overview

BudBridge streams audio from a Windows 11 PC to an iOS device, enabling users to listen to PC audio through AirPods connected to their iPhone.

## Architecture

- **iOS App** (`AirpodPcAudio/`): SwiftUI app that receives and plays audio
- **Windows App** (`windows/`): Rust application that captures and streams PC audio

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
- SwiftUI for UI
- AVFoundation for audio playback
- Network framework for connectivity

## Agent Commands

### "windows deploy"
Build and copy the Windows exe to the Downloads folder for easy access:
```bash
cd /home/samdk/code/BudBridge/windows && \
. "$HOME/.cargo/env" && \
cargo build --release --target x86_64-pc-windows-gnu && \
cp target/x86_64-pc-windows-gnu/release/airpod-pc-audio.exe /mnt/c/Users/samdk/Downloads/
```

## Project Structure

```
BudBridge/
├── AirpodPcAudio/           # iOS app source
│   ├── AirpodPcAudioApp.swift
│   ├── ContentView.swift
│   ├── NetworkManager.swift
│   └── AudioManager.swift
├── AirpodPcAudio.xcodeproj/ # Xcode project
├── windows/                  # Windows Rust app
│   ├── .cargo/config.toml   # Cross-compilation config
│   ├── Cargo.toml
│   └── src/main.rs
└── airpod-pc-audio.exe      # Pre-built Windows binary
```
