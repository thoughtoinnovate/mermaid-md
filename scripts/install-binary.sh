#!/usr/bin/env bash
set -euo pipefail

REPO="thoughtoinnovate/mermaid-md"
VERSION="${1:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

uname_s="$(uname -s)"
uname_m="$(uname -m)"

case "$uname_s" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *) echo "Unsupported OS: $uname_s"; exit 1 ;;
esac

case "$uname_m" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) echo "Unsupported architecture: $uname_m"; exit 1 ;;
esac

if [[ "$os" == "linux" && "$arch" == "x86_64" ]]; then
  asset="linux-x86_64"
elif [[ "$os" == "linux" && "$arch" == "aarch64" ]]; then
  asset="linux-aarch64"
elif [[ "$os" == "macos" && "$arch" == "aarch64" ]]; then
  asset="macos-aarch64"
else
  echo "No published binary for ${os}-${arch} yet."; exit 1
fi

if [[ "$VERSION" == "latest" ]]; then
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
else
  tag="$VERSION"
fi

archive="mermaid-inline-${tag}-${asset}.tar.gz"
url="https://github.com/${REPO}/releases/download/${tag}/${archive}"

echo "Downloading $url"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl -fL "$url" -o "$tmp_dir/$archive"
tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"

mkdir -p "$INSTALL_DIR"
found_bin="$(find "$tmp_dir" -type f -name mermaid-inline | head -1)"
if [[ -z "$found_bin" ]]; then
  echo "Binary not found in archive"
  exit 1
fi

install -m 0755 "$found_bin" "$INSTALL_DIR/mermaid-inline"
echo "Installed: $INSTALL_DIR/mermaid-inline"
echo "Add to PATH if needed: export PATH=\"$INSTALL_DIR:\$PATH\""
