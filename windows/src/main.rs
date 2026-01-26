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
const DEVICES_FILE: &str = "budbridge_devices.txt";
const DEFAULT_DEVICE_FILE: &str = "budbridge_default.txt";
const TARGET_SAMPLE_RATE: u32 = 48000;

#[derive(Clone)]
struct SavedDevice {
    name: String,
    ip: String,
}

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
    packets_recv_with_audio: AtomicU64,
    audio_callbacks: AtomicU64,
    last_packets_sent: AtomicU64,
    last_packets_recv: AtomicU64,
    status_message: Mutex<String>,
    is_connected: AtomicBool,
}

struct AudioDeviceInfo {
    name: String,
}

#[derive(PartialEq, Default, Clone, Copy)]
enum Tab {
    #[default]
    Connection,
    Devices,
}

struct BudBridgeApp {
    current_tab: Tab,
    iphone_ip: String,
    input_devices: Vec<AudioDeviceInfo>,
    output_devices: Vec<AudioDeviceInfo>,
    selected_input: usize,
    selected_output: usize,
    state: Arc<AppState>,
    stop_flag: Arc<AtomicBool>,
    _audio_thread: Option<thread::JoinHandle<()>>,
    // Saved devices
    saved_devices: Vec<SavedDevice>,
    selected_device: Option<usize>,
    default_device: Option<usize>,
    // Add device form (inline on Devices tab)
    new_device_name: String,
    new_device_ip: String,
}

impl BudBridgeApp {
    fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let (input_devices, output_devices) = Self::enumerate_devices();
        let saved_devices = load_saved_devices();
        let default_device = load_default_device(&saved_devices);

        // Auto-select: use default device, or if only one device exists, use that
        let selected_device = if default_device.is_some() {
            default_device
        } else if saved_devices.len() == 1 {
            Some(0)
        } else {
            None
        };

        let iphone_ip = selected_device
            .and_then(|i| saved_devices.get(i))
            .map(|d| d.ip.clone())
            .unwrap_or_default();

        Self {
            current_tab: Tab::default(),
            iphone_ip,
            input_devices,
            output_devices,
            selected_input: 0,
            selected_output: 0,
            state: Arc::new(AppState::default()),
            stop_flag: Arc::new(AtomicBool::new(false)),
            _audio_thread: None,
            saved_devices,
            selected_device,
            default_device,
            new_device_name: String::new(),
            new_device_ip: String::new(),
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
            *self.state.status_message.lock() = "Please select a device first".to_string();
            return;
        }

        // Reset state
        self.stop_flag.store(false, Ordering::SeqCst);
        self.state.packets_sent.store(0, Ordering::SeqCst);
        self.state.packets_recv.store(0, Ordering::SeqCst);
        self.state.packets_recv_with_audio.store(0, Ordering::SeqCst);
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
            ui.add_space(5.0);

            // Tab bar
            ui.horizontal(|ui| {
                ui.selectable_value(&mut self.current_tab, Tab::Connection, "Connection");
                ui.selectable_value(&mut self.current_tab, Tab::Devices, "Devices");
            });
            ui.separator();
            ui.add_space(5.0);

            match self.current_tab {
                Tab::Connection => self.show_connection_tab(ui),
                Tab::Devices => self.show_devices_tab(ui),
            }
        });
    }
}

impl BudBridgeApp {
    fn show_connection_tab(&mut self, ui: &mut egui::Ui) {
        let is_connected = self.state.is_connected.load(Ordering::SeqCst);

        // Device selection
        ui.group(|ui| {
            ui.label("Target Device");
            ui.add_space(5.0);

            let selected_name = self
                .selected_device
                .and_then(|i| self.saved_devices.get(i))
                .map(|d| d.name.clone())
                .unwrap_or_else(|| "Select a device...".to_string());

            let mut new_selection: Option<usize> = None;

            ui.horizontal(|ui| {
                ui.label("Device:");
                ui.add_enabled_ui(!is_connected, |ui| {
                    egui::ComboBox::from_id_salt("saved_devices")
                        .width(200.0)
                        .selected_text(&selected_name)
                        .show_ui(ui, |ui| {
                            for (i, device) in self.saved_devices.iter().enumerate() {
                                if ui.selectable_value(&mut self.selected_device, Some(i), &device.name).changed() {
                                    new_selection = Some(i);
                                }
                            }
                        });
                });
            });

            if self.saved_devices.is_empty() {
                ui.label("No devices saved. Go to Devices tab to add one.");
            }

            // Apply selection change
            if let Some(i) = new_selection {
                if let Some(dev) = self.saved_devices.get(i) {
                    self.iphone_ip = dev.ip.clone();
                }
            }
        });

        ui.add_space(10.0);

        // Audio settings
        ui.group(|ui| {
            ui.label("Audio Settings");
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

                if ui.button("Refresh").clicked() {
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
            let recv_audio = self.state.packets_recv_with_audio.load(Ordering::Relaxed);
            let callbacks = self.state.audio_callbacks.load(Ordering::Relaxed);

            let last_sent = self.state.last_packets_sent.swap(sent, Ordering::Relaxed);
            let last_recv = self.state.last_packets_recv.swap(recv, Ordering::Relaxed);

            let sent_rate = (sent - last_sent) * 2;
            let recv_rate = (recv - last_recv) * 2;

            ui.label(format!("Packets Sent: {} (+{}/s)", sent, sent_rate));
            ui.label(format!("Packets Received: {} (+{}/s)", recv, recv_rate));
            ui.label(format!(
                "Packets with Audio: {} / {} ({:.0}%)",
                recv_audio,
                recv,
                if recv > 0 { recv_audio as f64 / recv as f64 * 100.0 } else { 0.0 }
            ));
            ui.label(format!("Audio Callbacks: {}", callbacks));
        });
    }

    fn show_devices_tab(&mut self, ui: &mut egui::Ui) {
        // Add new device
        ui.group(|ui| {
            ui.label("Add New Device");
            ui.add_space(5.0);

            ui.horizontal(|ui| {
                ui.label("Name:");
                ui.text_edit_singleline(&mut self.new_device_name);
            });

            ui.horizontal(|ui| {
                ui.label("IP:");
                ui.text_edit_singleline(&mut self.new_device_ip);
            });

            ui.add_space(5.0);

            if ui.button("Add Device").clicked() {
                if !self.new_device_name.is_empty() && !self.new_device_ip.is_empty() {
                    let is_first = self.saved_devices.is_empty();
                    self.saved_devices.push(SavedDevice {
                        name: self.new_device_name.clone(),
                        ip: self.new_device_ip.clone(),
                    });
                    save_devices(&self.saved_devices);

                    // Auto-set as default if it's the first/only device
                    if is_first {
                        self.default_device = Some(0);
                        self.selected_device = Some(0);
                        self.iphone_ip = self.new_device_ip.clone();
                        save_default_device(&self.saved_devices, Some(0));
                    }

                    self.new_device_name.clear();
                    self.new_device_ip.clear();
                }
            }
        });

        ui.add_space(10.0);

        // Saved devices list
        ui.group(|ui| {
            ui.label("Saved Devices");
            ui.add_space(5.0);

            if self.saved_devices.is_empty() {
                ui.label("No devices saved yet.");
            } else {
                let mut to_delete: Option<usize> = None;
                let mut new_default: Option<Option<usize>> = None;

                for (i, device) in self.saved_devices.iter().enumerate() {
                    ui.horizontal(|ui| {
                        let is_default = self.default_device == Some(i);
                        if ui.radio(is_default, "").clicked() {
                            new_default = Some(Some(i));
                        }
                        ui.label(format!("{} - {}", device.name, device.ip));
                        if is_default {
                            ui.label("(default)");
                        }
                        if ui.button("Delete").clicked() {
                            to_delete = Some(i);
                        }
                    });
                }

                // Handle default change
                if let Some(new_def) = new_default {
                    self.default_device = new_def;
                    save_default_device(&self.saved_devices, self.default_device);
                }

                // Handle delete
                if let Some(idx) = to_delete {
                    self.saved_devices.remove(idx);
                    save_devices(&self.saved_devices);

                    // Update selected_device
                    if self.selected_device == Some(idx) {
                        self.selected_device = None;
                        self.iphone_ip.clear();
                    } else if let Some(sel) = self.selected_device {
                        if sel > idx {
                            self.selected_device = Some(sel - 1);
                        }
                    }

                    // Update default_device
                    if self.default_device == Some(idx) {
                        self.default_device = None;
                        save_default_device(&self.saved_devices, None);
                    } else if let Some(def) = self.default_device {
                        if def > idx {
                            self.default_device = Some(def - 1);
                            save_default_device(&self.saved_devices, self.default_device);
                        }
                    }

                    // If only one device left, auto-set as default
                    if self.saved_devices.len() == 1 && self.default_device.is_none() {
                        self.default_device = Some(0);
                        save_default_device(&self.saved_devices, Some(0));
                    }
                }
            }
        });

        ui.add_space(10.0);

        // Tips
        ui.group(|ui| {
            ui.label("Tips");
            ui.add_space(5.0);
            ui.label("• Find your iPhone's IP in Settings > Wi-Fi > (i)");
            ui.label("• Make sure both devices are on the same network");
        });
    }
}

// Config file helpers
fn get_devices_path() -> PathBuf {
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(dir) = exe_path.parent() {
            return dir.join(DEVICES_FILE);
        }
    }
    PathBuf::from(DEVICES_FILE)
}

fn load_saved_devices() -> Vec<SavedDevice> {
    let path = get_devices_path();
    fs::read_to_string(&path)
        .ok()
        .map(|content| {
            content
                .lines()
                .filter_map(|line| {
                    let parts: Vec<&str> = line.splitn(2, '|').collect();
                    if parts.len() == 2 {
                        Some(SavedDevice {
                            name: parts[0].to_string(),
                            ip: parts[1].to_string(),
                        })
                    } else {
                        None
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

fn save_devices(devices: &[SavedDevice]) {
    let path = get_devices_path();
    let content: String = devices
        .iter()
        .map(|d| format!("{}|{}", d.name, d.ip))
        .collect::<Vec<_>>()
        .join("\n");
    let _ = fs::write(&path, content);
}

fn get_default_device_path() -> PathBuf {
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(dir) = exe_path.parent() {
            return dir.join(DEFAULT_DEVICE_FILE);
        }
    }
    PathBuf::from(DEFAULT_DEVICE_FILE)
}

fn load_default_device(devices: &[SavedDevice]) -> Option<usize> {
    let path = get_default_device_path();
    let default_name = fs::read_to_string(&path).ok()?.trim().to_string();
    devices.iter().position(|d| d.name == default_name)
}

fn save_default_device(devices: &[SavedDevice], index: Option<usize>) {
    let path = get_default_device_path();
    if let Some(idx) = index {
        if let Some(device) = devices.get(idx) {
            let _ = fs::write(&path, &device.name);
            return;
        }
    }
    let _ = fs::remove_file(&path);
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
                // Check if packet has actual audio (any sample above noise floor)
                let has_audio = samples.iter().any(|&s| s.abs() > 100);
                if has_audio {
                    state.packets_recv_with_audio.fetch_add(1, Ordering::Relaxed);
                }
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
