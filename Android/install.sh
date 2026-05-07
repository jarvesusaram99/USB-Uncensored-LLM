#!/data/data/com.termux/files/usr/bin/bash
# ================================================================
#  PORTABLE UNCENSORED AI - Android Native Installer (Llama.cpp)
# ================================================================
#  Natively compiles Llama.cpp on your device for max performance
#  and sets up the universal USB folder architecture.
# ================================================================

# ---- Detect Termux ----
if [ -z "$TERMUX_VERSION" ] && [ ! -d "/data/data/com.termux" ]; then
    echo "ERROR: This script must run inside Termux!"
    echo "Install Termux from F-Droid: https://f-droid.org/en/packages/com.termux/"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USB_ROOT="$(dirname "$SCRIPT_DIR")"
SHARED_DIR="$USB_ROOT/Shared"
SHARED_BIN="$SHARED_DIR/bin"
MODELS_DIR="$SHARED_DIR/models"
VENDOR_DIR="$SHARED_DIR/vendor"

mkdir -p "$SHARED_BIN" "$MODELS_DIR" "$VENDOR_DIR"

RED='\033[0;31m'
YLW='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
MAG='\033[0;35m'
GRY='\033[0;37m'
DGR='\033[1;30m'
WHT='\033[1;37m'
RST='\033[0m'

echo ""
echo -e "${CYN}==========================================================${RST}"
echo -e "${CYN}   PORTABLE AI - Android Native Setup (Llama.cpp)         ${RST}"
echo -e "${CYN}==========================================================${RST}"

# ================================================================
# 1. System & Dependencies
# ================================================================
echo -e "${YLW}[1/5] Preparing Termux environment...${RST}"

# Grant storage permission
if [ ! -d "$HOME/storage" ]; then
    echo -e "${DGR}      Requesting storage permission...${RST}"
    termux-setup-storage 2>/dev/null || true
    sleep 2
fi

echo -e "${DGR}      Updating packages and installing build tools...${RST}"
# Use apt instead of pkg to avoid caching bugs, full-upgrade ensures SSL libs are fixed
apt update -y
apt full-upgrade -y
pkg install -y clang cmake git wget ninja python

echo -e "${GRN}      Dependencies installed!${RST}"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN{printf \"%.1f\", $TOTAL_RAM_KB/1048576}")
echo -e "${DGR}      Device RAM: ${TOTAL_RAM_GB} GB${RST}"

# ================================================================
# 2 Download optional UI vendor assets for offline mode
# ================================================================
echo ""
echo -e "${YLW}[2/5] Downloading UI assets (offline markdown/pdf/fonts)...${RST}"
VENDOR_SCRIPT="$SHARED_DIR/scripts/download-ui-assets.sh"
if [ -f "$VENDOR_SCRIPT" ]; then
    bash "$VENDOR_SCRIPT" "$VENDOR_DIR"
else
    echo -e "${YLW}      WARNING: Shared vendor bootstrap script not found. Skipping.${RST}"
fi

# ================================================================
# 3. Compile Llama.cpp natively
# ================================================================
echo ""
echo -e "${YLW}[3/5] Preparing Llama.cpp Engine...${RST}"
cd "$SHARED_BIN"

if [ ! -d "llama.cpp" ]; then
    echo -e "${DGR}      Cloning llama.cpp source...${RST}"
    git clone https://github.com/ggerganov/llama.cpp.git
fi

cd llama.cpp
if [ ! -f "build/bin/llama-server" ]; then
    echo -e "${MAG}      Compiling engine natively for your processor...${RST}"
    echo -e "${MAG}      (This takes 10 to 30 minutes! Do not close Termux)${RST}"
    
    # Acquire wakelock so Android doesn't kill compilation
    termux-wake-lock 2>/dev/null || true
    
    rm -rf build 2>/dev/null
    cmake -B build -GNinja -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TESTS=OFF
    cmake --build build --config Release --target llama-server
    
    termux-wake-unlock 2>/dev/null || true
    echo -e "${GRN}      Compilation complete!${RST}"
else
    echo -e "${GRN}      Engine already compiled! Skipping...${RST}"
fi

cp build/bin/llama-server "$SHARED_BIN/llama-server-android" 2>/dev/null || true

# ----------------------------------------------------------------
# Android model catalog (shared JSON config)
# ----------------------------------------------------------------
CONFIG_QUERY="$SHARED_DIR/scripts/config_query.py"
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    echo -e "${RED}ERROR: Python is required to parse shared model config.${RST}"
    exit 1
fi

if [ ! -f "$CONFIG_QUERY" ]; then
    echo -e "${RED}ERROR: Missing shared config query script: $CONFIG_QUERY${RST}"
    exit 1
fi

eval "$("$PYTHON_CMD" "$CONFIG_QUERY" models-shell android)"

get_field() {
    local num=$1 field=$2
    eval echo "\${MODEL_${field}_${num}}"
}

# ================================================================
# 4. Model Retrieval
# ================================================================
echo ""
echo -e "${YLW}[4/5] AI Model Library...${RST}"

for NUM in "${MODEL_NUMS[@]}"; do
    NAME=$(get_field "$NUM" NAME)
    SIZE=$(get_field "$NUM" SIZE)
    LABEL=$(get_field "$NUM" LABEL)
    BADGE=$(get_field "$NUM" BADGE)
    if [ "$LABEL" = "UNCENSORED" ]; then
        LABEL_COLOR="$RED"
    else
        LABEL_COLOR="$CYN"
    fi
    echo -e "  ${YLW}[${NUM}]${RST} ${NAME} (${SIZE} GB) ${LABEL_COLOR}[${LABEL} - ${BADGE}]${RST}"
done
echo -e "  ${GRN}[C]${RST} CUSTOM - Paste HuggingFace .gguf direct link"
echo -e "  ${DGR}[0]${RST} Skip downloading (I already have models in Shared/models/)"
echo ""
read -r -p "  Select model (0-${#MODEL_NUMS[@]} or C): " MODEL_CHOICE

MODEL_URL=""
MODEL_CHOICE_L=$(echo "$MODEL_CHOICE" | tr '[:upper:]' '[:lower:]')
case "$MODEL_CHOICE_L" in
    c|custom)
        read -r -p "  Paste direct .gguf URL: " CUSTOM_URL
        if [ -n "$CUSTOM_URL" ]; then
            MODEL_URL="$CUSTOM_URL"
            MODEL_FILE=$(basename "${MODEL_URL%%\?*}")
            [[ "$MODEL_FILE" != *.gguf ]] && MODEL_FILE="${MODEL_FILE}.gguf"
        fi
        ;;
    0|skip)
        echo -e "${GRN}      Skipping download phase.${RST}"
        ;;
    *)
        if [[ "$MODEL_CHOICE_L" =~ ^[0-9]+$ ]]; then
            FOUND=false
            for NUM in "${MODEL_NUMS[@]}"; do
                if [ "$MODEL_CHOICE_L" -eq "$NUM" ]; then
                    MODEL_URL=$(get_field "$NUM" URL)
                    MODEL_FILE=$(get_field "$NUM" FILE)
                    FOUND=true
                    break
                fi
            done
            if ! $FOUND; then
                echo -e "${YLW}      Invalid choice. Defaulting to first model.${RST}"
                DEF="${MODEL_NUMS[0]}"
                MODEL_URL=$(get_field "$DEF" URL)
                MODEL_FILE=$(get_field "$DEF" FILE)
            fi
        else
            echo -e "${YLW}      Invalid choice. Defaulting to first model.${RST}"
            DEF="${MODEL_NUMS[0]}"
            MODEL_URL=$(get_field "$DEF" URL)
            MODEL_FILE=$(get_field "$DEF" FILE)
        fi
        ;;
esac

cd "$MODELS_DIR" || exit 1

if [ -n "$MODEL_URL" ]; then
    if [ -f "$MODEL_FILE" ]; then
        echo -e "${GRN}      $MODEL_FILE already downloaded!${RST}"
    else
        echo -e "${MAG}      Downloading $MODEL_FILE...${RST}"
        termux-wake-lock 2>/dev/null || true
        # Use wget -c to allow resuming broken downloads
        wget -c "$MODEL_URL" -O "$MODEL_FILE"
        termux-wake-unlock 2>/dev/null || true
        echo -e "${GRN}      Download complete!${RST}"
    fi
fi

# ================================================================
# 5. Final Summary
# ================================================================
echo ""
echo -e "${CYN}==========================================================${RST}"
echo -e "${GRN}[5/5]   ANDROID SETUP COMPLETE!${RST}"
echo -e "${CYN}==========================================================${RST}"
echo ""
echo -e "  Your engine has been natively compiled for your exact processor."
echo -e "  Models are universally stored in ${WHT}Shared/models/${RST}"
echo ""
echo -e "  ${GRY}To start the AI, run:${RST}"
echo -e "  ${WHT}bash Android/start.sh${RST}"
echo ""
read -n 1 -s -r -p "Press any key to close this installer..."
echo ""
