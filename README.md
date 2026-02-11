# mermaid-inline

Render Mermaid diagrams from Markdown files and display them inline in terminals that support the Kitty graphics protocol (Kitty, Ghostty).

## Prerequisites

- Rust toolchain (`cargo`, `rustc`)
- Node.js + npm
- Mermaid CLI:
  - `npm install -g @mermaid-js/mermaid-cli`
  - or `bun add -g @mermaid-js/mermaid-cli`
- Chromium/Chrome available for `mmdc` in container/headless setups

## Build

```bash
cargo build --release
```

Binary:

```bash
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

Add this plugin spec in your Lazy config (for example `~/.config/nvim/lua/plugins/mermaid.lua`):

```lua
return {
  {
    dir = "/home/dev/data/work/code/mermaid-md",
    name = "mermaid-inline.nvim",
    ft = { "markdown" },
    opts = {
      command = "/home/dev/data/work/code/mermaid-md/target/release/mermaid-inline",
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
    dir = "/home/dev/data/work/code/mermaid-md",
    name = "mermaid-inline.nvim",
    ft = { "markdown" },
    opts = {
      command = "/home/dev/data/work/code/mermaid-md/target/release/mermaid-inline",
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
nvim --headless /home/dev/data/work/code/mermaid-md/tests/fixtures/markdown_with_mermaid.md "+write" "+sleep 15" "+qa"
ls -la /tmp/mermaid-out
```

Expected files:

- `/tmp/mermaid-out/mermaid-1.png`
- `/tmp/mermaid-out/mermaid-2.png`
