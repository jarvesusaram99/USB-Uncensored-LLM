#!/usr/bin/env bash
set -u

VENDOR_DIR="${1:-}"
if [ -z "$VENDOR_DIR" ]; then
  echo "Usage: $0 <vendor_dir>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QUERY_SCRIPT="$SCRIPT_DIR/config_query.py"

if command -v python3 >/dev/null 2>&1; then
  PY_CMD="python3"
elif command -v python >/dev/null 2>&1; then
  PY_CMD="python"
else
  echo "      WARNING: Python not found; cannot parse shared JSON config for UI assets."
  exit 0
fi

mkdir -p "$VENDOR_DIR"

download_file() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail "$url" -o "$dest" >/dev/null 2>&1
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
    return $?
  fi
  return 127
}

echo "      Downloading shared UI vendor asset list..."
while IFS='|' read -r name url; do
  [ -z "${name:-}" ] && continue
  [ -z "${url:-}" ] && continue
  dest="$VENDOR_DIR/$name"
  echo "      -> $name"
  download_file "$url" "$dest"
  rc=$?
  if [ $rc -ne 0 ]; then
    rm -f "$dest"
    echo "         WARNING: Could not fetch $name. UI will fallback when online."
    continue
  fi
  bytes="$(wc -c < "$dest" 2>/dev/null || echo 0)"
  if [ "${bytes:-0}" -lt 1024 ]; then
    rm -f "$dest"
    echo "         WARNING: $name was too small. UI will fallback when online."
  fi
  # Patch Font Awesome CSS so font paths resolve from ./vendor/ instead of ../webfonts/
  if [ "$name" = "fa-all.min.css" ]; then
    sed -i 's|\.\./webfonts/|./|g' "$dest" 2>/dev/null || \
    sed -i '' 's|\.\./webfonts/|./|g' "$dest" 2>/dev/null || true
  fi
done < <("$PY_CMD" "$QUERY_SCRIPT" vendors)

echo "      UI asset bootstrap complete."
