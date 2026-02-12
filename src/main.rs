mod display;
mod extract;
mod render;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::display::{clear_inline, show_inline};
use crate::extract::extract_mermaid_blocks;
use crate::render::{RenderOptions, render_blocks};

#[derive(Parser, Debug)]
#[command(
    name = "mermaid-inline",
    version,
    about = "Render Mermaid blocks inline in Kitty"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Check dependencies and print install hints.
    Setup {
        /// Upgrade Mermaid CLI to latest using npm.
        #[arg(long)]
        upgrade: bool,
    },
    /// Render Mermaid blocks from a Markdown file.
    Render {
        /// Markdown file path.
        file: PathBuf,
        /// Display PNGs inline (Kitty).
        #[arg(long, default_value_t = true)]
        inline: bool,
        /// Output directory for PNGs (default: temp dir).
        #[arg(long)]
        out_dir: Option<PathBuf>,
        /// 1-based diagram index to render a single block.
        #[arg(long)]
        index: Option<usize>,
        /// Watch file and re-render on change.
        #[arg(long)]
        watch: bool,
        /// Clear previous inline images before rendering.
        #[arg(long)]
        clear: bool,
        /// Render scale passed to mmdc (e.g. 2.0 for higher resolution).
        #[arg(long)]
        scale: Option<f32>,
        /// Explicit output width passed to mmdc.
        #[arg(long)]
        width: Option<u32>,
        /// Explicit output height passed to mmdc.
        #[arg(long)]
        height: Option<u32>,
    },
}

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Setup { upgrade } => setup(upgrade),
        Commands::Render {
            file,
            inline,
            out_dir,
            index,
            watch,
            clear,
            scale,
            width,
            height,
        } => render_cmd(
            &file, inline, out_dir, index, watch, clear, scale, width, height,
        ),
    }
}

fn setup(upgrade: bool) -> Result<()> {
    let mut missing = Vec::new();
    if which::which("node").is_err() {
        missing.push("node");
    }
    if which::which("mmdc").is_err() {
        missing.push("mmdc");
    }
    if !missing.is_empty() {
        eprintln!("Missing dependencies: {}", missing.join(", "));
        eprintln!("Install hints:");
        if missing.contains(&"node") {
            eprintln!("- Install Node.js (node + npm) from https://nodejs.org");
        }
        if missing.contains(&"mmdc") {
            eprintln!("- npm install -g @mermaid-js/mermaid-cli");
            eprintln!("- or: bun add -g @mermaid-js/mermaid-cli");
        }
    } else {
        println!("All dependencies found.");
    }

    if upgrade {
        let status = Command::new("npm")
            .args(["install", "-g", "@mermaid-js/mermaid-cli@latest"])
            .status()
            .context("run npm install -g @mermaid-js/mermaid-cli@latest")?;
        if !status.success() {
            eprintln!("Upgrade failed. Try: sudo npm install -g @mermaid-js/mermaid-cli@latest");
        } else {
            println!("Mermaid CLI upgraded to latest.");
        }
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn render_cmd(
    file: &Path,
    inline: bool,
    out_dir: Option<PathBuf>,
    index: Option<usize>,
    watch: bool,
    clear: bool,
    scale: Option<f32>,
    width: Option<u32>,
    height: Option<u32>,
) -> Result<()> {
    let options = RenderOptions {
        scale,
        width,
        height,
    };

    if watch {
        watch_and_render(file, inline, out_dir, index, clear, &options)?;
        return Ok(());
    }
    render_once(file, inline, out_dir, index, clear, &options)
}

fn render_once(
    file: &Path,
    inline: bool,
    out_dir: Option<PathBuf>,
    index: Option<usize>,
    clear: bool,
    options: &RenderOptions,
) -> Result<()> {
    let markdown = fs::read_to_string(file).with_context(|| format!("read {}", file.display()))?;
    let mut blocks = extract_mermaid_blocks(&markdown);

    if let Some(i) = index {
        blocks.retain(|b| b.index == i);
    }

    if blocks.is_empty() {
        std::process::exit(2);
    }

    let out_dir = if let Some(dir) = out_dir {
        fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
        dir
    } else {
        tempfile::tempdir()
            .context("create temp output dir")?
            .keep()
    };

    let rendered = render_blocks(&blocks, &out_dir, options)?;

    if inline {
        if clear {
            clear_inline()?;
        }
        for diagram in rendered {
            show_inline(&diagram.output_path)?;
        }
    }

    Ok(())
}

fn watch_and_render(
    file: &Path,
    inline: bool,
    out_dir: Option<PathBuf>,
    index: Option<usize>,
    clear: bool,
    options: &RenderOptions,
) -> Result<()> {
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher: RecommendedWatcher = Watcher::new(tx, notify::Config::default())?;
    watcher.watch(file, RecursiveMode::NonRecursive)?;

    // Initial render
    let _ = render_once(file, inline, out_dir.clone(), index, clear, options);

    loop {
        match rx.recv() {
            Ok(_event) => {
                std::thread::sleep(Duration::from_millis(150));
                let _ = render_once(file, inline, out_dir.clone(), index, clear, options);
            }
            Err(err) => bail!("watch error: {err}"),
        }
    }
}
