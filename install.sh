#!/bin/sh
set -e

# Strata Installer
# Installs Strata to /usr/local/bin or ~/.local/bin via curl | sh

GITHUB_OWNER="quaywin"
GITHUB_REPO="strata"
BINARY_NAME="strata"

info() {
  printf "\033[1;32m=>\033[0m %s\n" "$1"
}

error() {
  printf "\033[1;31mError:\033[0m %s\n" "$1" >&2
  exit 1
}

# Detect OS
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  darwin)
    TARGET_OS="macos"
    ;;
  linux)
    TARGET_OS="linux"
    ;;
  *)
    error "Unsupported operating system: $OS. Strata currently supports macOS and Linux."
    ;;
esac

# Detect Architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    TARGET_ARCH="x86_64"
    ;;
  arm64|aarch64)
    TARGET_ARCH="aarch64"
    ;;
  *)
    error "Unsupported architecture: $ARCH. Strata currently supports x86_64 and aarch64."
    ;;
esac

BURRITO_TARGET="${TARGET_OS}_${TARGET_ARCH}"
RELEASE_FILE_NAME="${BINARY_NAME}_${BURRITO_TARGET}"

if [ "$BURRITO_TARGET" = "linux_aarch64" ] || [ "$BURRITO_TARGET" = "macos_x86_64" ]; then
  error "${BURRITO_TARGET} prebuilt binaries are not currently published in releases. Please build from source."
fi

# Determine version
if [ -z "$VERSION" ]; then
  info "Fetching latest version from GitHub..."
  LATEST_RELEASE_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest"
  VERSION=$(curl -sSL "$LATEST_RELEASE_URL" | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
  if [ -z "$VERSION" ]; then
    error "Could not auto-detect the latest version from GitHub API (might be rate-limited). Please specify VERSION (e.g. VERSION=v0.1.0 sh -c \"\$(curl -fsSL ...)\")."
  fi
fi

info "Selected version: $VERSION"

DOWNLOAD_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${VERSION}/${RELEASE_FILE_NAME}"

# Determine installation directory
if [ "$TARGET_OS" = "macos" ]; then
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
else
  INSTALL_DIR="/usr/local/bin"
  if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
    info "No write permission for /usr/local/bin, installing to $INSTALL_DIR instead."
  fi
fi

TEMP_FILE=$(mktemp)

info "Downloading Strata from $DOWNLOAD_URL ..."
if curl -sSL --fail -o "$TEMP_FILE" "$DOWNLOAD_URL"; then
  info "Download completed successfully."
else
  rm -f "$TEMP_FILE"
  error "Failed to download Strata from $DOWNLOAD_URL. Please ensure the release tag and binary exist."
fi

DEST_PATH="${INSTALL_DIR}/${BINARY_NAME}"
info "Installing binary to $DEST_PATH..."

mv "$TEMP_FILE" "$DEST_PATH"
chmod +x "$DEST_PATH"

# Pre-extract Burrito payload to avoid slow first start
info "Pre-extracting application payload (this may take a few seconds)..."
"$DEST_PATH" --version > /dev/null || true

info "Strata $VERSION installed successfully at $DEST_PATH!"

case :$PATH: in
  *:"$INSTALL_DIR":*) ;;
  *)
    info "WARNING: $INSTALL_DIR is not in your PATH."
    info "Add it to your shell config (e.g., ~/.bashrc, ~/.zshrc):"
    echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
    ;;
esac

info "Run 'strata' to start the database TUI manager."
