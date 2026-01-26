#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};
use eframe::egui;
use parking_lot::Mutex;
use std::fs;
use std::net::UdpSocket;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;

const RECEIVE_PORT: u16 = 4810;
const SEND_PORT: u16 = 4811;
const CONFIG_FILE: &str = "budbridge_config.txt";
const TARGET_SAMPLE_RATE: u32 = 24000;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([400.0, 450.0])
            .with_min_inner_size([350.0, 400.0]),
        ..Default::default()
    };

    eframe::run_native(
        "BudBridge",
        options,
        Box::new(|cc| Ok(Box::new(BudBridgeApp::new(cc)))),
    )
}

// Shared state between UI and audio/network threads
#[derive(Default)]
struct AppState {
    packets_sent: AtomicU64,
    packets_recv: AtomicU64,
    audio_callbacks: AtomicU64,
    last_packets_sent: AtomicU64,
    last_packets_recv: AtomicU64,
    status_message: Mutex<String>,
    is_connected: AtomicBool,
}

struct AudioDeviceInfo {
    name: String,
}

struct BudBridgeApp {
    iphone_ip: String,
    input_devices: Vec<AudioDeviceInfo>,
    output_devices: Vec<AudioDeviceInfo>,
    selected_input: usize,
    selected_output: usize,
    state: Arc<AppState>,
    stop_flag: Arc<AtomicBool>,
    _audio_thread: Option<thread::JoinHandle<()>>,
}

impl BudBridgeApp {
    fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let (input_devices, output_devices) = Self::enumerate_devices();
        let iphone_ip = load_cached_ip().unwrap_or_default();

        Self {
            iphone_ip,
            input_devices,
            output_devices,
            selected_input: 0,
            selected_output: 0,
            state: Arc::new(AppState::default()),
            stop_flag: Arc::new(AtomicBool::new(false)),
            _audio_thread: None,
        }
    }

    fn enumerate_devices() -> (Vec<AudioDeviceInfo>, Vec<AudioDeviceInfo>) {
        let host = cpal::default_host();

        let input_devices: Vec<AudioDeviceInfo> = host
            .input_devices()
            .map(|devices| {
                devices
                    .map(|d| AudioDeviceInfo {
                        name: d.name().unwrap_or_else(|_| "Unknown".to_string()),
                    })
                    .collect()
            })
            .unwrap_or_default();

        let output_devices: Vec<AudioDeviceInfo> = host
            .output_devices()
            .map(|devices| {
                devices
                    .map(|d| AudioDeviceInfo {
                        name: d.name().unwrap_or_else(|_| "Unknown".to_string()),
                    })
                    .collect()
            })
            .unwrap_or_default();

        (input_devices, output_devices)
    }

    fn refresh_devices(&mut self) {
        let (input, output) = Self::enumerate_devices();
        self.input_devices = input;
        self.output_devices = output;
        self.selected_input = 0;
        self.selected_output = 0;
    }

    fn connect(&mut self) {
        if self.iphone_ip.trim().is_empty() {
            *self.state.status_message.lock() = "Please enter iPhone IP address".to_string();
            return;
        }

        save_cached_ip(&self.iphone_ip);

        // Reset state
        self.stop_flag.store(false, Ordering::SeqCst);
        self.state.packets_sent.store(0, Ordering::SeqCst);
        self.state.packets_recv.store(0, Ordering::SeqCst);
        self.state.audio_callbacks.store(0, Ordering::SeqCst);
        self.state.is_connected.store(true, Ordering::SeqCst);
        *self.state.status_message.lock() = "Connecting...".to_string();

        let iphone_ip = self.iphone_ip.clone();
        let selected_input = self.selected_input;
        let selected_output = self.selected_output;
        let state = self.state.clone();
        let stop_flag = self.stop_flag.clone();

        self._audio_thread = Some(thread::spawn(move || {
            if let Err(e) = run_bridge(iphone_ip, selected_input, selected_output, state.clone(), stop_flag) {
                *state.status_message.lock() = format!("Error: {}", e);
                state.is_connected.store(false, Ordering::SeqCst);
            }
        }));
    }

    fn disconnect(&mut self) {
        self.stop_flag.store(true, Ordering::SeqCst);
        self.state.is_connected.store(false, Ordering::SeqCst);
        *self.state.status_message.lock() = "Disconnected".to_string();
        self._audio_thread = None;
    }
}

impl eframe::App for BudBridgeApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Request repaint for live stats
        ctx.request_repaint_after(std::time::Duration::from_millis(500));

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("BudBridge");
            ui.add_space(10.0);

            let is_connected = self.state.is_connected.load(Ordering::SeqCst);

            // Connection settings
            ui.group(|ui| {
                ui.label("Connection Settings");
                ui.add_space(5.0);

                ui.horizontal(|ui| {
                    ui.label("iPhone IP:");
                    ui.add_enabled(
                        !is_connected,
                        egui::TextEdit::singleline(&mut self.iphone_ip)
                            .hint_text("192.168.1.xxx")
                            .desired_width(150.0),
                    );
                });

                ui.add_space(5.0);

                ui.horizontal(|ui| {
                    ui.label("Input Device:");
                    egui::ComboBox::from_id_salt("input_device")
                        .width(200.0)
                        .selected_text(
                            self.input_devices
                                .get(self.selected_input)
                                .map(|d| d.name.as_str())
                                .unwrap_or("None"),
                        )
                        .show_ui(ui, |ui| {
                            for (i, device) in self.input_devices.iter().enumerate() {
                                ui.selectable_value(&mut self.selected_input, i, &device.name);
                            }
                        });
                });

                ui.horizontal(|ui| {
                    ui.label("Output Device:");
                    egui::ComboBox::from_id_salt("output_device")
                        .width(200.0)
                        .selected_text(
                            self.output_devices
                                .get(self.selected_output)
                                .map(|d| d.name.as_str())
                                .unwrap_or("None"),
                        )
                        .show_ui(ui, |ui| {
                            for (i, device) in self.output_devices.iter().enumerate() {
                                ui.selectable_value(&mut self.selected_output, i, &device.name);
                            }
                        });
                });

                ui.add_space(5.0);

                ui.horizontal(|ui| {
                    if !is_connected {
                        if ui.button("Connect").clicked() {
                            self.connect();
                        }
                    } else {
                        if ui.button("Disconnect").clicked() {
                            self.disconnect();
                        }
                    }

                    if ui.button("Refresh Devices").clicked() {
                        self.refresh_devices();
                    }
                });
            });

            ui.add_space(10.0);

            // Diagnostics
            ui.group(|ui| {
                ui.label("Diagnostics");
                ui.add_space(5.0);

                let status = self.state.status_message.lock().clone();
                let status_color = if is_connected {
                    egui::Color32::GREEN
                } else if status.starts_with("Error") {
                    egui::Color32::RED
                } else {
                    egui::Color32::GRAY
                };

                ui.horizontal(|ui| {
                    ui.label("Status:");
                    ui.colored_label(status_color, &status);
                });

                ui.add_space(5.0);

                let sent = self.state.packets_sent.load(Ordering::Relaxed);
                let recv = self.state.packets_recv.load(Ordering::Relaxed);
                let callbacks = self.state.audio_callbacks.load(Ordering::Relaxed);

                let last_sent = self.state.last_packets_sent.swap(sent, Ordering::Relaxed);
                let last_recv = self.state.last_packets_recv.swap(recv, Ordering::Relaxed);

                let sent_rate = (sent - last_sent) * 2; // per second (updating every 500ms)
                let recv_rate = (recv - last_recv) * 2;

                ui.label(format!("Packets Sent: {} (+{}/s)", sent, sent_rate));
                ui.label(format!("Packets Received: {} (+{}/s)", recv, recv_rate));
                ui.label(format!("Audio Callbacks: {}", callbacks));
            });

            ui.add_space(10.0);

            // Tips
            ui.group(|ui| {
                ui.label("Tips");
                ui.add_space(5.0);
                ui.label("• Set Windows input to 'Stereo Mix' or a loopback device");
                ui.label("  to capture system audio (what you hear)");
                ui.label("• Make sure iPhone app is running and on same network");
            });
        });
    }
}

// Config file helpers
fn get_config_path() -> PathBuf {
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(dir) = exe_path.parent() {
            return dir.join(CONFIG_FILE);
        }
    }
    PathBuf::from(CONFIG_FILE)
}

fn load_cached_ip() -> Option<String> {
    let path = get_config_path();
    fs::read_to_string(&path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn save_cached_ip(ip: &str) {
    let path = get_config_path();
    let _ = fs::write(&path, ip);
}

// Audio/Network bridge
fn run_bridge(
    iphone_ip: String,
    input_idx: usize,
    output_idx: usize,
    state: Arc<AppState>,
    stop_flag: Arc<AtomicBool>,
) -> Result<()> {
    let host = cpal::default_host();

    let input_device: Device = host
        .input_devices()?
        .nth(input_idx)
        .ok_or_else(|| anyhow!("Input device not found"))?;

    let output_device: Device = host
        .output_devices()?
        .nth(output_idx)
        .ok_or_else(|| anyhow!("Output device not found"))?;

    let input_config: StreamConfig = input_device.default_input_config()?.into();
    let output_config: StreamConfig = output_device.default_output_config()?.into();

    let input_channels = input_config.channels;
    let output_channels = output_config.channels;
    let input_sample_rate = input_config.sample_rate.0;

    // Channels for audio data
    let (mic_tx, mic_rx): (Sender<Vec<i16>>, Receiver<Vec<i16>>) = bounded(32);
    let (pc_tx, pc_rx): (Sender<Vec<i16>>, Receiver<Vec<i16>>) = bounded(32);

    let iphone_addr = format!("{}:{}", iphone_ip, SEND_PORT);

    // Update status
    *state.status_message.lock() = format!(
        "Connected to {} ({}Hz {}ch -> {}Hz)",
        iphone_ip, input_sample_rate, input_channels, TARGET_SAMPLE_RATE
    );

    // Start network thread
    let stop_net = stop_flag.clone();
    let state_net = state.clone();
    let iphone_addr_clone = iphone_addr.clone();
    let net_handle = thread::spawn(move || {
        let _ = run_network(stop_net, mic_rx, pc_tx, &iphone_addr_clone, state_net);
    });

    // Build streams
    let state_audio = state.clone();
    let input_stream = build_input_stream(
        &input_device,
        &input_config,
        mic_tx,
        input_channels,
        input_sample_rate,
        state_audio,
    )?;

    let output_stream = build_output_stream(&output_device, &output_config, pc_rx, output_channels)?;

    input_stream.play()?;
    output_stream.play()?;

    // Wait until stopped
    while !stop_flag.load(Ordering::SeqCst) {
        thread::sleep(std::time::Duration::from_millis(100));
    }

    drop(input_stream);
    drop(output_stream);
    net_handle.join().ok();

    Ok(())
}

fn run_network(
    stop_flag: Arc<AtomicBool>,
    mic_rx: Receiver<Vec<i16>>,
    pc_tx: Sender<Vec<i16>>,
    iphone_addr: &str,
    state: Arc<AppState>,
) -> Result<()> {
    let recv_socket = UdpSocket::bind(format!("0.0.0.0:{}", RECEIVE_PORT))?;
    recv_socket.set_nonblocking(true)?;

    let send_socket = UdpSocket::bind("0.0.0.0:0")?;

    let mut recv_buf = [0u8; 65536];

    while !stop_flag.load(Ordering::SeqCst) {
        // Receive mic audio from iPhone
        match recv_socket.recv_from(&mut recv_buf) {
            Ok((len, _src)) => {
                state.packets_recv.fetch_add(1, Ordering::Relaxed);
                let samples: Vec<i16> = recv_buf[..len]
                    .chunks_exact(2)
                    .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
                    .collect();
                let _ = pc_tx.try_send(samples);
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => {}
        }

        // Send PC audio to iPhone
        if let Ok(samples) = mic_rx.try_recv() {
            let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
            for chunk in bytes.chunks(1400) {
                let _ = send_socket.send_to(chunk, iphone_addr);
                state.packets_sent.fetch_add(1, Ordering::Relaxed);
            }
        }

        thread::sleep(std::time::Duration::from_micros(100));
    }

    Ok(())
}

fn build_input_stream(
    device: &Device,
    config: &StreamConfig,
    tx: Sender<Vec<i16>>,
    channels: u16,
    input_sample_rate: u32,
    state: Arc<AppState>,
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("Input stream error: {}", err);

    let downsample_ratio = if input_sample_rate > TARGET_SAMPLE_RATE {
        input_sample_rate / TARGET_SAMPLE_RATE
    } else {
        1
    };

    let stream = device.build_input_stream(
        config,
        move |data: &[f32], _: &cpal::InputCallbackInfo| {
            state.audio_callbacks.fetch_add(1, Ordering::Relaxed);

            let mono_samples: Vec<f32> = if channels == 2 {
                data.chunks(2)
                    .map(|chunk| (chunk.get(0).unwrap_or(&0.0) + chunk.get(1).unwrap_or(&0.0)) / 2.0)
                    .collect()
            } else {
                data.to_vec()
            };

            let downsampled: Vec<i16> = mono_samples
                .iter()
                .step_by(downsample_ratio as usize)
                .map(|&s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
                .collect();

            let _ = tx.try_send(downsampled);
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

    let buffer: Arc<std::sync::Mutex<Vec<f32>>> = Arc::new(std::sync::Mutex::new(Vec::new()));
    let buffer_clone = buffer.clone();

    thread::spawn(move || {
        while let Ok(samples) = rx.recv() {
            let floats: Vec<f32> = samples.iter().map(|&s| s as f32 / 32768.0).collect();
            if let Ok(mut buf) = buffer_clone.lock() {
                buf.extend(floats);
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
