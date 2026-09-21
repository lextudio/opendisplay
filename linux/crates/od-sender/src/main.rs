mod capture;
mod hyprland;

use std::time::{Duration, Instant};

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing::info;

/// OpenDisplay sender for Linux (work in progress).
#[derive(Parser, Debug)]
#[command(version, about)]
struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// List Hyprland monitors over IPC.
    Monitors,
    /// Create, size and remove a headless output through Hyprland IPC.
    HeadlessTest {
        #[arg(long, default_value = "od-test")]
        name: String,
        #[arg(long, default_value_t = 2560)]
        width: u32,
        #[arg(long, default_value_t = 1600)]
        height: u32,
        #[arg(long, default_value_t = 60)]
        hz: u32,
        #[arg(long, default_value_t = 2.0)]
        scale: f64,
        /// Keep the output alive this long before removing it.
        #[arg(long, default_value_t = 2.0)]
        hold: f64,
    },
    /// Capture an output via ext-image-copy-capture into shm and report frame timing.
    CaptureTest {
        /// wl_output name; default: first output.
        #[arg(long)]
        output: Option<String>,
        #[arg(long, default_value_t = 5.0)]
        seconds: f64,
        #[arg(long)]
        cursor: bool,
        /// Write the last frame as a PPM here.
        #[arg(long)]
        save: Option<std::path::PathBuf>,
    },
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();
    match Args::parse().cmd {
        Cmd::Monitors => {
            let ipc = hyprland::HyprlandIpc::from_env()?;
            info!("{}", ipc.version()?);
            for m in ipc.monitors()? {
                info!(
                    "{} {}x{} @{:.0} scale {} at {},{} ({})",
                    m.name, m.width, m.height, m.refresh_rate, m.scale, m.x, m.y, m.description
                );
            }
        }
        Cmd::HeadlessTest {
            name,
            width,
            height,
            hz,
            scale,
            hold,
        } => {
            let ipc = hyprland::HyprlandIpc::from_env()?;
            let t = Instant::now();
            ipc.create_headless(&name)?;
            let m = ipc.configure(&name, width, height, hz, scale, "auto-right")?;
            info!(
                "created {} as {}x{} @{:.0} scale {} at {},{} in {:?}",
                m.name,
                m.width,
                m.height,
                m.refresh_rate,
                m.scale,
                m.x,
                m.y,
                t.elapsed()
            );
            std::thread::sleep(Duration::from_secs_f64(hold));
            ipc.remove_output(&name)?;
            info!(
                "removed {name}; monitors now: {:?}",
                ipc.monitors()?
                    .iter()
                    .map(|m| m.name.clone())
                    .collect::<Vec<_>>()
            );
        }
        Cmd::CaptureTest {
            output,
            seconds,
            cursor,
            save,
        } => {
            let mut last: Option<(capture::FrameInfo, Vec<u8>)> = None;
            let n = capture::capture_shm(
                output.as_deref(),
                cursor,
                Duration::from_secs_f64(seconds),
                |info, pixels| {
                    if save.is_some() {
                        last = Some((*info, pixels.to_vec()));
                    }
                },
            )?;
            info!("{n} frames captured");
            if let (Some(path), Some((info, pixels))) = (save, last) {
                let mut ppm = format!("P6\n{} {}\n255\n", info.width, info.height).into_bytes();
                for row in pixels.chunks(info.stride as usize) {
                    for px in row[..(info.width * 4) as usize].chunks(4) {
                        // XRGB8888 / ARGB8888 little-endian: B, G, R, X
                        ppm.extend_from_slice(&[px[2], px[1], px[0]]);
                    }
                }
                std::fs::write(&path, ppm)?;
                info!("wrote {}", path.display());
            }
        }
    }
    Ok(())
}
