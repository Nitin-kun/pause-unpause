#!/usr/bin/env bash
# pause-unpause installer
# Downloads the extension and sets up a one-command Chrome launcher.
set -euo pipefail

REPO_SLUG="${PAUSE_UNPAUSE_REPO:-Nitin-kun/pause-unpause}"
PREFIX="${PREFIX:-$HOME/.local/share/pause-unpause}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LAUNCH=1
UNINSTALL=0

usage() {
  cat <<'EOF'
Usage: install.sh [--no-launch] [--uninstall] [--prefix DIR]

  Downloads pause-unpause and sets it up so you can run:

      pause-unpause

  That opens Chrome with the extension already loaded.

  --no-launch   Install only; do not open Chrome
  --uninstall   Remove the installed files and launcher
  --prefix DIR  Install data directory (default: ~/.local/share/pause-unpause)

Chrome will not let a script silently add an extension to your everyday
browser. This installer gives you a dedicated Chrome window instead, which
is the closest thing to one-command setup.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

EXT_DIR="$PREFIX/extension"
PROFILE_DIR="$PREFIX/chrome-profile"
LAUNCHER="$BIN_DIR/pause-unpause"

remove_path() {
  if command -v rm >/dev/null 2>&1; then
    rm -rf "$1"
  fi
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  remove_path "$PREFIX"
  remove_path "$LAUNCHER"
  remove_path "$HOME/.local/share/applications/pause-unpause.desktop"
  echo "pause-unpause removed."
  exit 0
fi

script_dir() {
  local src="${BASH_SOURCE[0]}"
  if [[ ! -f "$src" ]]; then
    echo ""
    return
  fi
  (cd "$(dirname "$src")" && pwd -P)
}

find_extension_src() {
  local dir
  dir="$(script_dir)"
  if [[ -n "$dir" && -f "$dir/browser-extension/manifest.json" ]]; then
    echo "$dir/browser-extension"
    return
  fi
  if [[ -n "$dir" && -f "$dir/manifest.json" ]]; then
    echo "$dir"
    return
  fi
  echo ""
}

download_extension() {
  local tmp dest
  tmp="$(mktemp -d)"
  dest="$1"
  echo "Downloading pause-unpause from GitHub ($REPO_SLUG)..."
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "https://github.com/${REPO_SLUG}.git" "$tmp/repo"
    if [[ -f "$tmp/repo/browser-extension/manifest.json" ]]; then
      cp -a "$tmp/repo/browser-extension/." "$dest/"
    elif [[ -f "$tmp/repo/manifest.json" ]]; then
      cp -a "$tmp/repo/." "$dest/"
    else
      echo "Downloaded repo, but could not find the extension files." >&2
      remove_path "$tmp"
      exit 1
    fi
  else
    if ! command -v curl >/dev/null 2>&1; then
      echo "Need git or curl to download pause-unpause." >&2
      exit 1
    fi
    curl -fsSL "https://github.com/${REPO_SLUG}/archive/refs/heads/main.tar.gz" | tar -xz -C "$tmp"
    local extracted
    extracted="$(find "$tmp" -maxdepth 3 -name manifest.json -print -quit)"
    if [[ -z "$extracted" ]]; then
      echo "Download succeeded, but manifest.json was missing." >&2
      remove_path "$tmp"
      exit 1
    fi
    cp -a "$(dirname "$extracted")/." "$dest/"
  fi
  remove_path "$tmp"
}

find_browser() {
  local candidate
  for candidate in \
    google-chrome \
    google-chrome-stable \
    chromium \
    chromium-browser \
    microsoft-edge \
    brave-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
    "/mnt/c/Program Files/Microsoft/Edge/Application/msedge.exe"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return
    fi
  done
  echo ""
}

SRC="$(find_extension_src)"
mkdir -p "$EXT_DIR" "$PROFILE_DIR" "$BIN_DIR"
remove_path "$EXT_DIR"
mkdir -p "$EXT_DIR"

if [[ -n "$SRC" ]]; then
  echo "Installing from local files..."
  cp -a "$SRC/." "$EXT_DIR/"
else
  download_extension "$EXT_DIR"
fi

if [[ ! -f "$EXT_DIR/manifest.json" ]]; then
  echo "Install failed: manifest.json is missing from $EXT_DIR" >&2
  exit 1
fi

BROWSER="$(find_browser)"
if [[ -z "$BROWSER" ]]; then
  echo "Installed the files, but no Chrome / Chromium / Edge / Brave was found." >&2
  echo "Load this folder in chrome://extensions as an unpacked extension:" >&2
  echo "  $EXT_DIR"
  exit 1
fi

cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
EXT_DIR=$(printf '%q' "$EXT_DIR")
PROFILE_DIR=$(printf '%q' "$PROFILE_DIR")
BROWSER=$(printf '%q' "$BROWSER")

ext="\$EXT_DIR"
profile="\$PROFILE_DIR"
if [[ "\$BROWSER" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
  ext="\$(wslpath -w "\$EXT_DIR")"
  profile="\$(wslpath -w "\$PROFILE_DIR")"
fi

exec "\$BROWSER" \\
  --user-data-dir="\$profile" \\
  --load-extension="\$ext" \\
  --no-first-run \\
  --no-default-browser-check
EOF
chmod +x "$LAUNCHER"

if [[ -d "$HOME/.local/share/applications" ]]; then
  cat > "$HOME/.local/share/applications/pause-unpause.desktop" <<EOF
[Desktop Entry]
Name=pause-unpause
Comment=Lecture plays, type beat waits
Exec=$LAUNCHER
Terminal=false
Type=Application
Categories=Education;AudioVideo;
EOF
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Add this to your shell config so the command is found:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

echo
echo "pause-unpause is set up."
echo "  Extension: $EXT_DIR"
echo "  Command:   $LAUNCHER"
echo
echo "Run:  pause-unpause"
echo
echo "To add it to the Chrome you already use instead:"
echo "  1. Open chrome://extensions"
echo "  2. Turn on Developer mode"
echo "  3. Load unpacked"
echo "  4. Pick: $EXT_DIR"

if [[ "$LAUNCH" -eq 1 ]]; then
  echo
  echo "Opening Chrome with pause-unpause loaded..."
  nohup "$LAUNCHER" >/dev/null 2>&1 &
fi
