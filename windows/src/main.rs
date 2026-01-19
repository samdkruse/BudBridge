use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleRate, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::io::{self, Write};

const SAMPLE_RATE: u32 = 48000;
const CHANNELS: u16 = 1;
const RECEIVE_PORT: u16 = 4810; // Receive mic audio from iPhone
const SEND_PORT: u16 = 4811;    // Send PC audio to iPhone

fn main() -> Result<()> {
    println!("AirPod PC Audio Bridge");
    println!("======================\n");

    // Get iPhone IP from user
    print!("Enter iPhone IP address: ");
    io::stdout().flush()?;
    let mut iphone_ip = String::new();
    io::stdin().read_line(&mut iphone_ip)?;
    let iphone_ip = iphone_ip.trim().to_string();

    if iphone_ip.is_empty() {
        return Err(anyhow!("IP address required"));
    }

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

    // Start network threads
    let running_net = running.clone();
    let iphone_addr_clone = iphone_addr.clone();
    let net_handle = thread::spawn(move || {
        run_network(running_net, mic_rx, pc_tx, &iphone_addr_clone)
    });

    // Start audio
    let running_audio = running.clone();
    run_audio(running_audio, mic_tx, pc_rx)?;

    net_handle.join().ok();
    println!("Goodbye!");

    Ok(())
}

fn run_network(
    running: Arc<AtomicBool>,
    mic_rx: Receiver<Vec<i16>>,
    pc_tx: Sender<Vec<i16>>,
    iphone_addr: &str,
) -> Result<()> {
    // Socket for receiving iPhone mic audio
    let recv_socket = UdpSocket::bind(format!("0.0.0.0:{}", RECEIVE_PORT))?;
    recv_socket.set_nonblocking(true)?;
    println!("Listening for iPhone mic on port {}", RECEIVE_PORT);

    // Socket for sending PC audio to iPhone
    let send_socket = UdpSocket::bind("0.0.0.0:0")?;
    println!("Sending PC audio to {}", iphone_addr);

    let mut recv_buf = [0u8; 4096];

    while running.load(Ordering::SeqCst) {
        // Receive mic audio from iPhone
        match recv_socket.recv_from(&mut recv_buf) {
            Ok((len, _src)) => {
                // Convert bytes to i16 samples
                let samples: Vec<i16> = recv_buf[..len]
                    .chunks_exact(2)
                    .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
                    .collect();
                pc_tx.try_send(samples).ok();
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => eprintln!("Receive error: {}", e),
        }

        // Send PC audio to iPhone
        if let Ok(samples) = mic_rx.try_recv() {
            let bytes: Vec<u8> = samples
                .iter()
                .flat_map(|s| s.to_le_bytes())
                .collect();
            send_socket.send_to(&bytes, iphone_addr).ok();
        }

        thread::sleep(std::time::Duration::from_micros(100));
    }

    Ok(())
}

fn run_audio(
    running: Arc<AtomicBool>,
    mic_tx: Sender<Vec<i16>>,
    pc_rx: Receiver<Vec<i16>>,
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

    // Configure streams
    let config = StreamConfig {
        channels: CHANNELS,
        sample_rate: SampleRate(SAMPLE_RATE),
        buffer_size: cpal::BufferSize::Fixed(1024),
    };

    // Input stream - capture audio and send to iPhone
    let input_stream = build_input_stream(&input_device, &config, mic_tx)?;

    // Output stream - play iPhone mic audio
    let output_stream = build_output_stream(&output_device, &config, pc_rx)?;

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

fn build_input_stream(
    device: &Device,
    config: &StreamConfig,
    tx: Sender<Vec<i16>>,
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("Input stream error: {}", err);

    let stream = device.build_input_stream(
        config,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            // Convert f32 to i16
            let samples: Vec<i16> = data
                .iter()
                .map(|&s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
                .collect();
            tx.try_send(samples).ok();
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
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("Output stream error: {}", err);

    // Buffer for smooth playback
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
                // Limit buffer size to ~200ms
                let max_samples = (SAMPLE_RATE as usize) / 5;
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
                for sample in data.iter_mut() {
                    *sample = buf.pop().unwrap_or(0.0);
                }
            }
        },
        err_fn,
        None,
    )?;

    Ok(stream)
}
