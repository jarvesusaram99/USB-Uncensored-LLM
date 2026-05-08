#!/data/data/com.termux/files/usr/bin/bash

if [ -z "$TERMUX_VERSION" ] && [ ! -d "/data/data/com.termux" ]; then
  echo "ERROR: This script must run inside Termux."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USB_ROOT="$(dirname "$SCRIPT_DIR")"
COMMON_UNINSTALL="$USB_ROOT/Shared/scripts/uninstall-common.sh"

if [ ! -f "$COMMON_UNINSTALL" ]; then
  echo "ERROR: Missing shared uninstaller script:"
  echo "  $COMMON_UNINSTALL"
  exit 1
fi

bash "$COMMON_UNINSTALL" android
