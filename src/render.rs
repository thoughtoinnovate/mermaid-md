use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use tempfile::NamedTempFile;

use crate::extract::MermaidBlock;

pub struct RenderedDiagram {
    pub output_path: PathBuf,
}

#[derive(Debug, Clone, Default)]
pub struct RenderOptions {
    pub scale: Option<f32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

fn detect_chrome_executable() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("MMDC_CHROME_PATH")
        && !path.trim().is_empty()
    {
        return Some(PathBuf::from(path));
    }

    let candidates = [
        "chromium",
        "chromium-browser",
        "google-chrome",
        "google-chrome-stable",
    ];

    for candidate in candidates {
        if let Ok(path) = which::which(candidate) {
            return Some(path);
        }
    }

    None
}

fn build_puppeteer_config() -> Result<Option<NamedTempFile>> {
    let chrome = match detect_chrome_executable() {
        Some(path) => path,
        None => return Ok(None),
    };

    let mut config = NamedTempFile::new().context("create temporary puppeteer config")?;
    let json = format!(
        "{{\n  \"executablePath\": \"{}\",\n  \"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\", \"--disable-dev-shm-usage\"]\n}}\n",
        chrome.to_string_lossy()
    );
    std::io::Write::write_all(&mut config, json.as_bytes())
        .context("write temporary puppeteer config")?;
    Ok(Some(config))
}

pub fn render_blocks(
    blocks: &[MermaidBlock],
    out_dir: &Path,
    options: &RenderOptions,
) -> Result<Vec<RenderedDiagram>> {
    let mut rendered = Vec::with_capacity(blocks.len());
    let puppeteer_config = build_puppeteer_config()?;

    for block in blocks {
        let mut tmp = NamedTempFile::new().context("create temp .mmd file")?;
        std::io::Write::write_all(&mut tmp, block.code.as_bytes())
            .context("write mermaid code to temp file")?;

        let output_path = out_dir.join(format!("mermaid-{}.png", block.index));

        let mut cmd = Command::new("mmdc");
        cmd.args([
            "-i",
            tmp.path().to_string_lossy().as_ref(),
            "-o",
            output_path.to_string_lossy().as_ref(),
            "--quiet",
        ]);

        if let Some(config) = &puppeteer_config {
            cmd.args(["-p", config.path().to_string_lossy().as_ref()]);
        }

        if let Some(scale) = options.scale {
            cmd.args(["--scale", scale.to_string().as_ref()]);
        }
        if let Some(width) = options.width {
            cmd.args(["--width", width.to_string().as_ref()]);
        }
        if let Some(height) = options.height {
            cmd.args(["--height", height.to_string().as_ref()]);
        }

        let output = cmd.output().context("run mmdc")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            bail!("mmdc failed for diagram {}: {}", block.index, stderr.trim());
        }

        rendered.push(RenderedDiagram { output_path });
    }

    Ok(rendered)
}
