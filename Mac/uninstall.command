#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USB_ROOT="$(dirname "$SCRIPT_DIR")"
COMMON_UNINSTALL="$USB_ROOT/Shared/scripts/uninstall-common.sh"

if [ ! -f "$COMMON_UNINSTALL" ]; then
  echo "ERROR: Missing shared uninstaller script:"
  echo "  $COMMON_UNINSTALL"
  exit 1
fi

bash "$COMMON_UNINSTALL" mac
