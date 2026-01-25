use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::io::{self, Write};
use std::fs;
use std::path::PathBuf;

const RECEIVE_PORT: u16 = 4810; // Receive mic audio from iPhone
const SEND_PORT: u16 = 4811;    // Send PC audio to iPhone
const CONFIG_FILE: &str = "budbridge_config.txt";

fn get_config_path() -> PathBuf {
    // Store config next to exe, or in current dir
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(dir) = exe_path.parent() {
            return dir.join(CONFIG_FILE);
        }
    }
    PathBuf::from(CONFIG_FILE)
}

fn load_cached_ip() -> Option<String> {
    let path = get_config_path();
    fs::read_to_string(&path).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn save_cached_ip(ip: &str) {
    let path = get_config_path();
    let _ = fs::write(&path, ip);
}

fn main() -> Result<()> {
    println!("AirPod PC Audio Bridge");
    println!("======================\n");

    // Check for cached IP
    let cached_ip = load_cached_ip();

    let iphone_ip = if let Some(ref cached) = cached_ip {
        print!("Enter iPhone IP address [{}]: ", cached);
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let input = input.trim();
        if input.is_empty() {
            cached.clone()
        } else {
            input.to_string()
        }
    } else {
        print!("Enter iPhone IP address: ");
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        input.trim().to_string()
    };

    if iphone_ip.is_empty() {
        return Err(anyhow!("IP address required"));
    }

    // Save for next time
    save_cached_ip(&iphone_ip);

    let iphone_addr = format!("{}:{}", iphone_ip, SEND_PORT);
    println!("\nWill send PC audio to: {}", iphone_addr);
    println!("Listening for iPhone mic on port: {}\n", RECEIVE_PORT);

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    ctrlc::set_handler(move || {
        println!("\nShutting down...");
        r.store(false, Ordering::SeqCst);
    }).ok();

    // Channels for audio data
    let (mic_tx, mic_rx): (Sender<Vec<i16>>, Receiver<Vec<i16>>) = bounded(32);
    let (pc_tx, pc_rx): (Sender<Vec<i16>>, Receiver<Vec<i16>>) = bounded(32);

    // Debug counters
    let packets_sent = Arc::new(AtomicU64::new(0));
    let packets_recv = Arc::new(AtomicU64::new(0));
    let audio_callbacks = Arc::new(AtomicU64::new(0));

    // Start network threads
    let running_net = running.clone();
    let iphone_addr_clone = iphone_addr.clone();
    let packets_sent_net = packets_sent.clone();
    let packets_recv_net = packets_recv.clone();
    let net_handle = thread::spawn(move || {
        run_network(running_net, mic_rx, pc_tx, &iphone_addr_clone, packets_sent_net, packets_recv_net)
    });

    // Start debug stats thread
    let running_stats = running.clone();
    let packets_sent_stats = packets_sent.clone();
    let packets_recv_stats = packets_recv.clone();
    let audio_callbacks_stats = audio_callbacks.clone();
    thread::spawn(move || {
        let mut last_sent = 0u64;
        let mut last_recv = 0u64;
        let mut last_callbacks = 0u64;
        while running_stats.load(Ordering::SeqCst) {
            thread::sleep(std::time::Duration::from_secs(2));
            let sent = packets_sent_stats.load(Ordering::Relaxed);
            let recv = packets_recv_stats.load(Ordering::Relaxed);
            let callbacks = audio_callbacks_stats.load(Ordering::Relaxed);
            println!(
                "[STATS] Sent: {} (+{}), Recv: {} (+{}), AudioCB: {} (+{})",
                sent, sent - last_sent,
                recv, recv - last_recv,
                callbacks, callbacks - last_callbacks
            );
            last_sent = sent;
            last_recv = recv;
            last_callbacks = callbacks;
        }
    });

    // Start audio
    let running_audio = running.clone();
    run_audio(running_audio, mic_tx, pc_rx, audio_callbacks)?;

    net_handle.join().ok();
    println!("Goodbye!");

    Ok(())
}

fn run_network(
    running: Arc<AtomicBool>,
    mic_rx: Receiver<Vec<i16>>,
    pc_tx: Sender<Vec<i16>>,
    iphone_addr: &str,
    packets_sent: Arc<AtomicU64>,
    packets_recv: Arc<AtomicU64>,
) -> Result<()> {
    // Socket for receiving iPhone mic audio
    let recv_socket = UdpSocket::bind(format!("0.0.0.0:{}", RECEIVE_PORT))?;
    recv_socket.set_nonblocking(true)?;
    println!("Listening for iPhone mic on port {}", RECEIVE_PORT);

    // Socket for sending PC audio to iPhone
    let send_socket = UdpSocket::bind("0.0.0.0:0")?;
    println!("Sending PC audio to {}", iphone_addr);

    let mut recv_buf = [0u8; 65536]; // Max UDP payload size

    while running.load(Ordering::SeqCst) {
        // Receive mic audio from iPhone
        match recv_socket.recv_from(&mut recv_buf) {
            Ok((len, src)) => {
                packets_recv.fetch_add(1, Ordering::Relaxed);
                // Convert bytes to i16 samples
                let samples: Vec<i16> = recv_buf[..len]
                    .chunks_exact(2)
                    .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
                    .collect();
                if pc_tx.try_send(samples).is_err() {
                    eprintln!("[DEBUG] pc_tx channel full, dropping packet from {}", src);
                }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => eprintln!("Receive error: {}", e),
        }

        // Send PC audio to iPhone (chunked to avoid UDP fragmentation)
        if let Ok(samples) = mic_rx.try_recv() {
            let bytes: Vec<u8> = samples
                .iter()
                .flat_map(|s| s.to_le_bytes())
                .collect();
            // Send in chunks of ~1400 bytes (safe for MTU)
            for chunk in bytes.chunks(1400) {
                if let Err(e) = send_socket.send_to(chunk, iphone_addr) {
                    eprintln!("[DEBUG] Send error: {}", e);
                }
                packets_sent.fetch_add(1, Ordering::Relaxed);
            }
        }

        thread::sleep(std::time::Duration::from_micros(100));
    }

    Ok(())
}

fn run_audio(
    running: Arc<AtomicBool>,
    mic_tx: Sender<Vec<i16>>,
    pc_rx: Receiver<Vec<i16>>,
    audio_callbacks: Arc<AtomicU64>,
) -> Result<()> {
    let host = cpal::default_host();

    // List available devices
    println!("Available audio devices:");
    println!("------------------------");

    println!("\nInput devices (for capturing PC audio):");
    for (i, device) in host.input_devices()?.enumerate() {
        let name = device.name().unwrap_or_else(|_| "Unknown".to_string());
        println!("  [{}] {}", i, name);
    }

    println!("\nOutput devices (for playing iPhone mic):");
    for (i, device) in host.output_devices()?.enumerate() {
        let name = device.name().unwrap_or_else(|_| "Unknown".to_string());
        println!("  [{}] {}", i, name);
    }

    // Get default devices
    let input_device = host
        .default_input_device()
        .ok_or_else(|| anyhow!("No input device found"))?;
    let output_device = host
        .default_output_device()
        .ok_or_else(|| anyhow!("No output device found"))?;

    println!("\nUsing input: {}", input_device.name()?);
    println!("Using output: {}", output_device.name()?);
    println!("\nTip: Set Windows default input to 'Stereo Mix' or loopback device");
    println!("     to capture system audio (what you hear).\n");

    // Use device's default configs
    let input_supported = input_device.default_input_config()?;
    let output_supported = output_device.default_output_config()?;

    let input_config: StreamConfig = input_supported.clone().into();
    let output_config: StreamConfig = output_supported.clone().into();

    let input_channels = input_config.channels;
    let output_channels = output_config.channels;
    let input_sample_rate = input_config.sample_rate.0;
    let output_sample_rate = output_config.sample_rate.0;

    println!("Input: {} Hz, {} ch", input_sample_rate, input_channels);
    println!("Output: {} Hz, {} ch\n", output_sample_rate, output_channels);

    // Input stream - capture audio and send to iPhone
    // iPhone runs at 24kHz, so we need to downsample if input is 48kHz
    let input_stream = build_input_stream(&input_device, &input_config, mic_tx, input_channels, input_sample_rate, audio_callbacks)?;

    // Output stream - play iPhone mic audio
    let output_stream = build_output_stream(&output_device, &output_config, pc_rx, output_channels)?;

    input_stream.play()?;
    output_stream.play()?;

    println!("Audio bridge running. Press Ctrl+C to stop.\n");

    while running.load(Ordering::SeqCst) {
        thread::sleep(std::time::Duration::from_millis(100));
    }

    drop(input_stream);
    drop(output_stream);

    Ok(())
}

const TARGET_SAMPLE_RATE: u32 = 24000; // iPhone runs at 24kHz

fn build_input_stream(
    device: &Device,
    config: &StreamConfig,
    tx: Sender<Vec<i16>>,
    channels: u16,
    input_sample_rate: u32,
    audio_callbacks: Arc<AtomicU64>,
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("Input stream error: {}", err);

    // Calculate downsample ratio (e.g., 48000/24000 = 2)
    let downsample_ratio = if input_sample_rate > TARGET_SAMPLE_RATE {
        input_sample_rate / TARGET_SAMPLE_RATE
    } else {
        1
    };

    println!("[DEBUG] Downsampling: {}Hz -> {}Hz (ratio: {})",
             input_sample_rate, TARGET_SAMPLE_RATE, downsample_ratio);

    let stream = device.build_input_stream(
        config,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            audio_callbacks.fetch_add(1, Ordering::Relaxed);

            // Convert to mono first
            let mono_samples: Vec<f32> = if channels == 2 {
                data.chunks(2)
                    .map(|chunk| {
                        (chunk.get(0).unwrap_or(&0.0) + chunk.get(1).unwrap_or(&0.0)) / 2.0
                    })
                    .collect()
            } else {
                data.to_vec()
            };

            // Downsample by taking every Nth sample
            let downsampled: Vec<i16> = mono_samples
                .iter()
                .step_by(downsample_ratio as usize)
                .map(|&s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
                .collect();

            if tx.try_send(downsampled).is_err() {
                eprintln!("[DEBUG] mic_tx channel full, dropping audio");
            }
        },
        err_fn,
        None,
    )?;

    Ok(stream)
}

fn build_output_stream(
    device: &Device,
    config: &StreamConfig,
    rx: Receiver<Vec<i16>>,
    channels: u16,
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("Output stream error: {}", err);

    // Buffer for smooth playback (stores mono samples)
    let buffer: Arc<std::sync::Mutex<Vec<f32>>> = Arc::new(std::sync::Mutex::new(Vec::new()));
    let buffer_clone = buffer.clone();

    // Thread to receive and buffer audio
    thread::spawn(move || {
        while let Ok(samples) = rx.recv() {
            let floats: Vec<f32> = samples
                .iter()
                .map(|&s| s as f32 / 32768.0)
                .collect();
            if let Ok(mut buf) = buffer_clone.lock() {
                buf.extend(floats);
                // Limit buffer size to ~200ms worth of mono samples
                let max_samples = 48000 / 5;
                let current_len = buf.len();
                if current_len > max_samples {
                    buf.drain(0..current_len - max_samples);
                }
            }
        }
    });

    let stream = device.build_output_stream(
        config,
        move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
            if let Ok(mut buf) = buffer.lock() {
                if channels == 2 {
                    // Duplicate mono to stereo
                    for chunk in data.chunks_mut(2) {
                        let sample = if !buf.is_empty() { buf.remove(0) } else { 0.0 };
                        chunk[0] = sample;
                        if chunk.len() > 1 {
                            chunk[1] = sample;
                        }
                    }
                } else {
                    for sample in data.iter_mut() {
                        *sample = if !buf.is_empty() { buf.remove(0) } else { 0.0 };
                    }
                }
            }
        },
        err_fn,
        None,
    )?;

    Ok(stream)
}
