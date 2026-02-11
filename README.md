# mermaid-inline

Render Mermaid diagrams from Markdown files and display them inline in terminals that support the Kitty graphics protocol (Kitty, Ghostty).

## Quick start (no Rust required)

Install latest released binary:

```bash
curl -fsSL https://raw.githubusercontent.com/thoughtoinnovate/mermaid-md/master/scripts/install-binary.sh | bash
```

Install specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/thoughtoinnovate/mermaid-md/master/scripts/install-binary.sh | bash -s -- v0.1.0
```

Then ensure `~/.local/bin` is on PATH.

## Prerequisites

- Node.js + npm
- Mermaid CLI:
  - `npm install -g @mermaid-js/mermaid-cli`
  - or `bun add -g @mermaid-js/mermaid-cli`
- Chromium/Chrome available for `mmdc` in container/headless setups

## Build from source (optional)

```bash
cargo build --release
./target/release/mermaid-inline
```

## CLI usage

```bash
# dependency check
mermaid-inline setup

# render all mermaid blocks from markdown
mermaid-inline render /path/to/file.md --inline --clear

# render to files only (headless-friendly)
mermaid-inline render /path/to/file.md --out-dir /tmp/mermaid-out

# watch mode
mermaid-inline render /path/to/file.md --watch --out-dir /tmp/mermaid-out
```

## Caching behavior

- Mermaid block content is hashed.
- If the same block text was rendered before, cached PNG is reused.
- Cache path:
  - `$XDG_CACHE_HOME/mermaid-inline/` if set
  - else `$HOME/.cache/mermaid-inline/`

## Neovim (lazy.nvim)

Add this plugin spec (for example `~/.config/nvim/lua/plugins/mermaid.lua`):

```lua
return {
  {
    "thoughtoinnovate/mermaid-md",
    ft = { "markdown" },
    build = "bash scripts/install-binary.sh",
    opts = {
      command = "mermaid-inline",
      auto_render = true,
      pattern = "*.md",
      preview_height = 12,
      open_preview_on_render = true,
      render_args = { "--inline", "--clear" },
    },
    config = function(_, opts)
      require("mermaid_inline").setup(opts)
    end,
  },
}
```

Available commands:

- `:MermaidInlineOpenPreview`
- `:MermaidInlineRender`
- `:MermaidInlineRender /full/path/file.md`
- `:MermaidInlineToggleAuto`

## Neovim headless test

For CI/container/headless verification, use file output mode:

```lua
return {
  {
    "thoughtoinnovate/mermaid-md",
    ft = { "markdown" },
    build = "bash scripts/install-binary.sh",
    opts = {
      command = "mermaid-inline",
      auto_render = true,
      open_preview_on_render = false,
      pattern = "*.md",
      render_args = { "--out-dir", "/tmp/mermaid-out" },
    },
    config = function(_, opts)
      require("mermaid_inline").setup(opts)
    end,
  },
}
```

Run test:

```bash
rm -rf /tmp/mermaid-out && mkdir -p /tmp/mermaid-out
nvim --headless tests/fixtures/markdown_with_mermaid.md "+write" "+sleep 15" "+qa"
ls -la /tmp/mermaid-out
```

Expected files:

- `/tmp/mermaid-out/mermaid-1.png`
- `/tmp/mermaid-out/mermaid-2.png`

## GitHub Actions release flow

- CI workflow: `.github/workflows/ci.yml`
  - Runs `cargo test`, `cargo fmt -- --check`, `cargo clippy`.
- Release workflow: `.github/workflows/release.yml`
  - Triggered on tag push `v*`.
  - Builds binaries for Linux/macOS/Windows.
  - Uploads packaged artifacts and publishes them to GitHub Releases.

To publish a new version:

```bash
git tag v0.1.0
git push origin v0.1.0
```
