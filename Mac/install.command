#!/bin/bash
# ================================================================
#  PORTABLE UNCENSORED AI - Mac Setup Script
# ================================================================
#  Multi-Model Edition: Choose one or more AI models to install!
#  Supports preset models + custom HuggingFace GGUF downloads.
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USB_ROOT="$(dirname "$SCRIPT_DIR")"
SHARED_DIR="$USB_ROOT/Shared"
SHARED_BIN="$SHARED_DIR/bin"
MODELS_DIR="$SHARED_DIR/models"
OLLAMA_DATA="$MODELS_DIR/ollama_data"

mkdir -p "$SHARED_BIN" "$MODELS_DIR" "$OLLAMA_DATA"

# ----------------------------------------------------------------
# Colors
# ----------------------------------------------------------------
RED='\033[0;31m'
YLW='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
MAG='\033[0;35m'
GRY='\033[0;37m'
DGR='\033[1;30m'
WHT='\033[1;37m'
RST='\033[0m'

# ----------------------------------------------------------------
# MODEL CATALOG (shared JSON config)
# ----------------------------------------------------------------
CONFIG_QUERY="$SHARED_DIR/scripts/config_query.py"
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    echo -e "${RED}ERROR: Python is required to parse shared model config.${RST}"
    echo -e "${RED}Install python3, then rerun this installer.${RST}"
    exit 1
fi

if [ ! -f "$CONFIG_QUERY" ]; then
    echo -e "${RED}ERROR: Missing shared config query script: $CONFIG_QUERY${RST}"
    exit 1
fi

eval "$("$PYTHON_CMD" "$CONFIG_QUERY" models-shell desktop)"

# ----------------------------------------------------------------
# Helper: get field by model number
# ----------------------------------------------------------------
get_field() {
    local num=$1 field=$2
    eval echo "\${MODEL_${field}_${num}}"
}

# ----------------------------------------------------------------
# Helper: check file is bigger than min bytes
# ----------------------------------------------------------------
file_ok() {
    local path=$1 minbytes=$2
    [ -f "$path" ] || return 1
    local size
    size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
    [ "$size" -gt "$minbytes" ]
}

# ----------------------------------------------------------------
# Helper: check file is a valid Mach-O binary (not an HTML page)
# On Mac, Mach-O magic bytes: feedface / feedfacf / cffaedfe / cefaedfe
# ----------------------------------------------------------------
is_macho() {
    local path=$1
    [ -f "$path" ] || return 1
    local magic
    magic=$(head -c 4 "$path" 2>/dev/null | xxd -p 2>/dev/null || head -c 4 "$path" 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    case "$magic" in
        feedface|feedfacf|cffaedfe|cefaedfe) return 0 ;;
        cafebabe|cafebabf) return 0 ;;  # Universal/Fat binary
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------
# Helper: disk free space in GB (integer, macOS df)
# ----------------------------------------------------------------
free_gb() {
    df -g "$USB_ROOT" 2>/dev/null | awk 'NR==2{print $4}' || echo -1
}

# ================================================================
# HEADER
# ================================================================
echo ""
echo -e "${CYN}==========================================================${RST}"
echo -e "${CYN}   PORTABLE AI USB - Multi-Model Setup (Mac)              ${RST}"
echo -e "${CYN}==========================================================${RST}"
echo ""

FREE=$(free_gb)
if [ "$FREE" -gt 0 ] 2>/dev/null; then
    echo -e "${DGR}  Drive Free Space: ${FREE} GB${RST}"
    echo ""
fi

# ================================================================
# STEP 1: MODEL SELECTION MENU
# ================================================================
echo -e "${YLW}[1/7] Choose your AI model(s):${RST}"
echo ""

for NUM in "${MODEL_NUMS[@]}"; do
    NAME=$(get_field "$NUM" NAME)
    SIZE=$(get_field "$NUM" SIZE)
    LABEL=$(get_field "$NUM" LABEL)
    BADGE=$(get_field "$NUM" BADGE)

    if [ "$LABEL" = "UNCENSORED" ]; then
        LABEL_STR="${RED}[UNCENSORED]${RST}"
    else
        LABEL_STR="${CYN}[STANDARD]${RST}"
    fi

    BADGE_STR=""
    [ -n "$BADGE" ] && BADGE_STR="${MAG} - ${BADGE}${RST}"

    echo -e "  ${YLW}[${NUM}]${RST} ${WHT}${NAME}${RST} ${DGR}(~${SIZE} GB)${RST} ${LABEL_STR}${BADGE_STR}"
done

echo ""
echo -e "  ${GRN}[C] CUSTOM - Enter your own HuggingFace GGUF URL${RST}"
echo ""
echo -e "  ${DGR}------------------------------------------------${RST}"
echo -e "  ${GRY}Enter number(s) separated by commas  (e.g. 1,3)${RST}"
echo -e "  ${GRY}Type 'all' for every preset model${RST}"
echo -e "  ${GRY}Type 'c' to add a custom model${RST}"
echo -e "  ${GRY}Mix them!  (e.g. 1,3,c)${RST}"
echo ""
read -r -p "  Your choice: " USER_CHOICE

if [ -z "$USER_CHOICE" ]; then
    echo ""
    echo -e "${YLW}  No input! Defaulting to [1] Gemma 2 2B (recommended)...${RST}"
    USER_CHOICE="1"
fi

# ----------------------------------------------------------------
# Parse selection
# ----------------------------------------------------------------
SELECTED_NUMS=()
HAS_CUSTOM=false
CUSTOM_FILE=""
CUSTOM_URL=""
CUSTOM_LOCAL=""
CUSTOM_PROMPT=""

CHOICE_LOWER=$(echo "$USER_CHOICE" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

if [ "$CHOICE_LOWER" = "all" ]; then
    SELECTED_NUMS=(1 2 3 4 5 6)
else
    IFS=',' read -ra TOKENS <<< "$CHOICE_LOWER"
    for TOKEN in "${TOKENS[@]}"; do
        T=$(echo "$TOKEN" | tr -d ' ')
        if [ "$T" = "c" ] || [ "$T" = "custom" ]; then
            HAS_CUSTOM=true
        elif [[ "$T" =~ ^[0-9]+$ ]]; then
            VALID=false
            for N in "${MODEL_NUMS[@]}"; do [ "$T" -eq "$N" ] && VALID=true && break; done
            if $VALID; then
                ALREADY=false
                for S in "${SELECTED_NUMS[@]}"; do [ "$S" -eq "$T" ] && ALREADY=true && break; done
                $ALREADY || SELECTED_NUMS+=("$T")
            else
                echo -e "${RED}  Invalid number '$T' - skipping (valid: 1-6)${RST}"
            fi
        else
            echo -e "${RED}  Unrecognized input '$T' - skipping${RST}"
        fi
    done
fi

# ----------------------------------------------------------------
# Custom model input
# ----------------------------------------------------------------
if $HAS_CUSTOM; then
    echo ""
    echo -e "${GRN}  ---- Custom Model Setup ----${RST}"
    echo -e "${GRY}  Paste a direct link to a .gguf file from HuggingFace.${RST}"
    echo -e "${DGR}  Example: https://huggingface.co/user/model-GGUF/resolve/main/model-Q4_K_M.gguf${RST}"
    echo ""
    read -r -p "  GGUF URL: " CUSTOM_URL_RAW
    CUSTOM_URL=$(echo "$CUSTOM_URL_RAW" | tr -d ' ')

    if [ -z "$CUSTOM_URL" ]; then
        echo -e "${RED}  No URL entered - skipping custom model.${RST}"
        HAS_CUSTOM=false
    else
        if [[ "$CUSTOM_URL" != *.gguf* ]]; then
            echo -e "${RED}  WARNING: URL does not contain .gguf - this may not be a valid model file.${RST}"
            read -r -p "  Try anyway? (yes/no): " PROCEED
            PROCEED_L=$(echo "$PROCEED" | tr '[:upper:]' '[:lower:]')
            if [ "$PROCEED_L" != "yes" ] && [ "$PROCEED_L" != "y" ]; then
                echo -e "${YLW}  Skipping custom model.${RST}"
                HAS_CUSTOM=false; CUSTOM_URL=""
            fi
        fi
    fi

    if $HAS_CUSTOM && [ -n "$CUSTOM_URL" ]; then
        CUSTOM_FILE=$(basename "${CUSTOM_URL%%\?*}")
        [[ "$CUSTOM_FILE" != *.gguf ]] && CUSTOM_FILE="${CUSTOM_FILE}.gguf"
        read -r -p "  Give it a short name (e.g. mymodel-local): " CUSTOM_LOCAL_RAW
        CUSTOM_LOCAL=$(echo "${CUSTOM_LOCAL_RAW:-custom}" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]/-/g')
        [[ "$CUSTOM_LOCAL" != *-local ]] && CUSTOM_LOCAL="${CUSTOM_LOCAL}-local"
        read -r -p "  System prompt (press Enter for default): " CUSTOM_PROMPT
        [ -z "$CUSTOM_PROMPT" ] && CUSTOM_PROMPT="You are a helpful AI assistant."
        echo -e "${GRN}  Custom model added!${RST}"
    fi
fi

# ----------------------------------------------------------------
# Validate at least one model selected
# ----------------------------------------------------------------
if [ "${#SELECTED_NUMS[@]}" -eq 0 ] && ! $HAS_CUSTOM; then
    echo ""
    echo -e "${RED}  ERROR: No models selected!${RST}"
    echo -e "${RED}  Please run the installer again and pick at least one model.${RST}"
    echo ""
    read -n 1 -s -r -p "Press any key to exit..."
    echo ""; exit 1
fi

# ----------------------------------------------------------------
# Space warning for 3+ models
# ----------------------------------------------------------------
TOTAL_SIZE=0
for NUM in "${SELECTED_NUMS[@]}"; do
    S=$(get_field "$NUM" SIZE)
    TOTAL_SIZE=$(awk "BEGIN{print $TOTAL_SIZE + $S}")
done

TOTAL_COUNT=${#SELECTED_NUMS[@]}
$HAS_CUSTOM && TOTAL_COUNT=$((TOTAL_COUNT + 1))

if [ "$TOTAL_COUNT" -ge 3 ] || [ "$CHOICE_LOWER" = "all" ]; then
    NEEDED=$(awk "BEGIN{print int($TOTAL_SIZE + 4) + 1}")
    echo ""
    echo -e "${RED}  =============================================${RST}"
    echo -e "${RED}  WARNING: You selected ${TOTAL_COUNT} models!${RST}"
    echo -e "${RED}  Estimated download: ~${TOTAL_SIZE} GB${RST}"
    echo -e "${RED}  Need at least ~${NEEDED} GB free on the drive!${RST}"
    echo -e "${RED}  =============================================${RST}"
    echo ""
    read -r -p "  Continue? (yes/no): " CONT
    CONT_L=$(echo "$CONT" | tr '[:upper:]' '[:lower:]')
    if [ "$CONT_L" != "yes" ] && [ "$CONT_L" != "y" ]; then
        echo -e "${YLW}  Cancelled.${RST}"
        read -n 1 -s -r -p "Press any key to exit..."; echo ""; exit 0
    fi
fi

# ----------------------------------------------------------------
# Show selection summary
# ----------------------------------------------------------------
echo ""
echo -e "${GRN}  Selected model(s):${RST}"
for NUM in "${SELECTED_NUMS[@]}"; do
    NAME=$(get_field "$NUM" NAME); SIZE=$(get_field "$NUM" SIZE)
    echo -e "    ${WHT}+ ${NAME} (~${SIZE} GB)${RST}"
done
$HAS_CUSTOM && echo -e "    ${WHT}+ Custom: ${CUSTOM_FILE}${RST}"
echo ""

# ================================================================
# STEP 2: Folder structure
# ================================================================
echo -e "${YLW}[2/7] Verifying folder structure...${RST}"
mkdir -p "$MODELS_DIR" "$SHARED_BIN" "$OLLAMA_DATA"
VENDOR_DIR="$SHARED_DIR/vendor"
mkdir -p "$VENDOR_DIR"
echo -e "${GRN}      Done.${RST}"

# ================================================================
# STEP 3: Download optional UI vendor assets for offline mode
# ================================================================
echo ""
echo -e "${YLW}[3/7] Downloading UI assets (offline markdown/pdf/fonts)...${RST}"
VENDOR_SCRIPT="$SHARED_DIR/scripts/download-ui-assets.sh"
if [ -f "$VENDOR_SCRIPT" ]; then
  bash "$VENDOR_SCRIPT" "$VENDOR_DIR"
else
  echo -e "${YLW}      WARNING: Shared vendor bootstrap script not found. Skipping.${RST}"
fi

# ================================================================
# STEP 4: Download AI models
# ================================================================
echo ""
echo -e "${YLW}[4/7] Downloading AI Model(s)...${RST}"

DOWNLOAD_ERRORS=()
MODEL_INDEX=0
TOTAL_MODELS=$((${#SELECTED_NUMS[@]} + ($HAS_CUSTOM && true || false)))

download_model() {
    local NUM=$1
    local NAME FILE URL MINB
    NAME=$(get_field "$NUM" NAME); FILE=$(get_field "$NUM" FILE)
    URL=$(get_field "$NUM" URL); MINB=$(get_field "$NUM" MINB)

    MODEL_INDEX=$((MODEL_INDEX + 1))
    DEST="$MODELS_DIR/$FILE"
    SIZE=$(get_field "$NUM" SIZE)

    echo ""
    echo -e "  ${YLW}(${MODEL_INDEX}/${TOTAL_MODELS}) ${NAME} (~${SIZE} GB)${RST}"

    if file_ok "$DEST" "$MINB"; then
        echo -e "${GRN}      Already downloaded! Skipping...${RST}"; return
    fi

    # Legacy dolphin Q5 check
    if [ "$(get_field "$NUM" LOCAL)" = "dolphin-local" ]; then
        LEGACY="$MODELS_DIR/dolphin-2.9-llama3-8b-Q5_K_M.gguf"
        if file_ok "$LEGACY" 4000000000; then
            echo -e "${GRN}      Found existing Dolphin Q5_K_M - using that instead!${RST}"
            eval "MODEL_FILE_${NUM}=dolphin-2.9-llama3-8b-Q5_K_M.gguf"; return
        fi
    fi

    echo -e "${MAG}      Downloading... This may take a while. Do NOT close this window!${RST}"

    SUCCESS=false
    for ATTEMPT in 1 2; do
        [ "$ATTEMPT" -gt 1 ] && echo -e "${YLW}      Retry attempt ${ATTEMPT}...${RST}"
        curl -L "$URL" -o "$DEST"
        if file_ok "$DEST" "$MINB"; then SUCCESS=true; break
        else
            ACTUAL=$(stat -f%z "$DEST" 2>/dev/null || echo 0)
            ACTUAL_GB=$(awk "BEGIN{printf \"%.2f\", $ACTUAL/1073741824}")
            echo -e "${RED}      File seems too small (${ACTUAL_GB} GB). May be incomplete.${RST}"
        fi
    done

    if $SUCCESS; then
        echo -e "${GRN}      Download complete!${RST}"
    else
        DOWNLOAD_ERRORS+=("$NAME")
        echo -e "${RED}      ERROR: Download failed for ${NAME}!${RST}"
        echo -e "${DGR}      Manual URL: ${URL}${RST}"
        echo -e "${DGR}      Place the file in: ${MODELS_DIR}/${RST}"
    fi
}

for NUM in "${SELECTED_NUMS[@]}"; do download_model "$NUM"; done

if $HAS_CUSTOM && [ -n "$CUSTOM_URL" ]; then
    MODEL_INDEX=$((MODEL_INDEX + 1))
    DEST="$MODELS_DIR/$CUSTOM_FILE"
    echo ""
    echo -e "  ${YLW}(${MODEL_INDEX}/${TOTAL_MODELS}) Custom: ${CUSTOM_FILE}${RST}"
    if file_ok "$DEST" 100000000; then
        echo -e "${GRN}      Already downloaded! Skipping...${RST}"
    else
        echo -e "${MAG}      Downloading custom model...${RST}"
        curl -L "$CUSTOM_URL" -o "$DEST"
        if file_ok "$DEST" 100000000; then
            echo -e "${GRN}      Download complete!${RST}"
        else
            DOWNLOAD_ERRORS+=("Custom: $CUSTOM_FILE")
            echo -e "${RED}      ERROR: Custom model download failed!${RST}"
        fi
    fi
fi

# ================================================================
# STEP 5: Create Modelfile configurations
# ================================================================
echo ""
echo -e "${YLW}[5/7] Creating AI model configurations...${RST}"

FIRST_LOCAL=""; FIRST_FILE=""; FIRST_PROMPT=""

write_modelfile() {
    local LOCAL=$1 FILE=$2 PROMPT=$3
    printf 'FROM ./%s\nPARAMETER temperature 0.7\nPARAMETER top_p 0.9\nSYSTEM %s\n' \
        "$FILE" "$PROMPT" > "$MODELS_DIR/Modelfile-${LOCAL}"
}

for NUM in "${SELECTED_NUMS[@]}"; do
    LOCAL=$(get_field "$NUM" LOCAL); FILE=$(get_field "$NUM" FILE)
    PROMPT=$(get_field "$NUM" PROMPT); NAME=$(get_field "$NUM" NAME)
    write_modelfile "$LOCAL" "$FILE" "$PROMPT"
    echo -e "${GRN}      Config: ${NAME} -> ${LOCAL}${RST}"
    [ -z "$FIRST_LOCAL" ] && FIRST_LOCAL="$LOCAL" && FIRST_FILE="$FILE" && FIRST_PROMPT="$PROMPT"
done

if $HAS_CUSTOM && [ -n "$CUSTOM_URL" ]; then
    write_modelfile "$CUSTOM_LOCAL" "$CUSTOM_FILE" "$CUSTOM_PROMPT"
    echo -e "${GRN}      Config: Custom -> ${CUSTOM_LOCAL}${RST}"
    [ -z "$FIRST_LOCAL" ] && FIRST_LOCAL="$CUSTOM_LOCAL" && FIRST_FILE="$CUSTOM_FILE" && FIRST_PROMPT="$CUSTOM_PROMPT"
fi

# Legacy single Modelfile
printf 'FROM ./%s\nPARAMETER temperature 0.7\nPARAMETER top_p 0.9\nSYSTEM %s\n' \
    "$FIRST_FILE" "$FIRST_PROMPT" > "$MODELS_DIR/Modelfile"

INSTALLED_LIST=""
for NUM in "${SELECTED_NUMS[@]}"; do
    LOCAL=$(get_field "$NUM" LOCAL); NAME=$(get_field "$NUM" NAME); LABEL=$(get_field "$NUM" LABEL)
    INSTALLED_LIST="${INSTALLED_LIST}${LOCAL}|${NAME}|${LABEL}\n"
done
$HAS_CUSTOM && INSTALLED_LIST="${INSTALLED_LIST}${CUSTOM_LOCAL}|Custom: ${CUSTOM_FILE}|CUSTOM\n"
printf "$INSTALLED_LIST" > "$MODELS_DIR/installed-models.txt"
echo -e "${DGR}      Saved model list to installed-models.txt${RST}"

# ================================================================
# STEP 6: Download Ollama Mac engine
# ================================================================
echo ""
echo -e "${YLW}[6/7] Downloading Ollama AI Engine (Mac)...${RST}"

OLLAMA_BIN="$SHARED_BIN/ollama-darwin"
ARCHIVE_URL="https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.tgz"

# Validate: must exist, be a real Mach-O binary, and > 10 MB
if [ -f "$OLLAMA_BIN" ] && is_macho "$OLLAMA_BIN" && file_ok "$OLLAMA_BIN" 10000000; then
    echo -e "${GRN}      Ollama already installed! Skipping...${RST}"
else
    rm -f "$OLLAMA_BIN"

    echo -e "      Downloading Ollama engine (streaming - stops after binary extracted)..."
    # Stream curl → tar: 'ollama' is the first entry in the tgz,
    # so tar exits as soon as it extracts it and the download stops early.
    curl -L --fail "$ARCHIVE_URL" | \
        tar -xzf - -C "$SHARED_BIN" ollama 2>/dev/null
    PIPE_RC=${PIPESTATUS[1]}

    # Rename extracted 'ollama' -> 'ollama-darwin'
    if [ -f "$SHARED_BIN/ollama" ]; then
        mv "$SHARED_BIN/ollama" "$OLLAMA_BIN"
    fi

    if [ "$PIPE_RC" -ne 0 ] || ! is_macho "$OLLAMA_BIN"; then
        echo -e "${RED}      ERROR: Extraction failed or binary is invalid!${RST}"
        rm -f "$OLLAMA_BIN"
        DOWNLOAD_ERRORS+=("Ollama Engine")
    else
        chmod +x "$OLLAMA_BIN"
        xattr -d com.apple.quarantine "$OLLAMA_BIN" 2>/dev/null
        echo -e "${GRN}      Ollama Mac Engine ready!${RST}"
    fi
fi

# ================================================================
# STEP 7: Import models into Ollama
# ================================================================
echo ""
echo -e "${YLW}[7/7] Importing AI models into the Ollama engine...${RST}"

if [ ! -x "$OLLAMA_BIN" ]; then
    echo -e "${RED}      ERROR: Ollama not found! Cannot import models.${RST}"
    echo -e "${RED}      Please re-run the installer to download Ollama.${RST}"
else
    OLLAMA_RUNTIME="$OLLAMA_DATA/../.ollama-runtime"
    mkdir -p "$OLLAMA_RUNTIME/runners" "$OLLAMA_RUNTIME/tmp"
    export OLLAMA_MODELS="$OLLAMA_DATA"
    export OLLAMA_HOME="$OLLAMA_RUNTIME"
    export OLLAMA_RUNNERS_DIR="$OLLAMA_RUNTIME/runners"
    export OLLAMA_TMPDIR="$OLLAMA_RUNTIME/tmp"
    export OLLAMA_ORIGINS="*"
    export OLLAMA_HOST="127.0.0.1:11434"

    # Kill any stale Ollama process
    pkill -f "ollama-darwin" 2>/dev/null
    sleep 2

    echo -e "${DGR}      Starting Ollama temporarily for import...${RST}"
    HOME="$OLLAMA_RUNTIME" "$OLLAMA_BIN" serve > "$OLLAMA_RUNTIME/install.log" 2>&1 &
    OLLAMA_PID=$!

    for i in $(seq 1 30); do
        curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1 && break
        sleep 1
    done

    cd "$MODELS_DIR" || exit 1

    import_model() {
        local LOCAL=$1 NAME=$2 FILE=$3 MINB=$4
        local GGUF="$MODELS_DIR/$FILE"
        if ! file_ok "$GGUF" "$MINB"; then
            echo -e "${RED}      Skipping ${NAME} - GGUF file not found or incomplete${RST}"; return
        fi
        echo -e "${YLW}      Importing ${NAME}...${RST}"
        "$OLLAMA_BIN" create "$LOCAL" -f "Modelfile-${LOCAL}" 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GRN}      ${NAME} imported successfully!${RST}"
        else
            echo -e "${RED}      ERROR: Failed to import ${NAME}${RST}"
        fi
    }

    for NUM in "${SELECTED_NUMS[@]}"; do
        import_model "$(get_field "$NUM" LOCAL)" "$(get_field "$NUM" NAME)" \
                     "$(get_field "$NUM" FILE)" "$(get_field "$NUM" MINB)"
    done

    if $HAS_CUSTOM && [ -n "$CUSTOM_URL" ]; then
        import_model "$CUSTOM_LOCAL" "Custom: $CUSTOM_FILE" "$CUSTOM_FILE" 100000000
    fi

    echo -e "${DGR}      Stopping temporary Ollama server...${RST}"
    kill "$OLLAMA_PID" 2>/dev/null
    wait "$OLLAMA_PID" 2>/dev/null
fi

# ================================================================
# FINAL SUMMARY
# ================================================================
echo ""
echo -e "${CYN}==========================================================${RST}"

if [ "${#DOWNLOAD_ERRORS[@]}" -gt 0 ]; then
    echo -e "${YLW}   SETUP COMPLETE (with some errors)                      ${RST}"
    echo -e "${CYN}==========================================================${RST}"
    echo ""
    echo -e "${RED}  The following had issues:${RST}"
    for ERR in "${DOWNLOAD_ERRORS[@]}"; do echo -e "${RED}    ! ${ERR}${RST}"; done
    echo ""
    echo -e "${YLW}  You can re-run install.command to retry failed downloads.${RST}"
else
    echo -e "${GRN}   SETUP COMPLETE! YOUR PORTABLE AI IS READY!             ${RST}"
    echo -e "${CYN}==========================================================${RST}"
fi

echo ""
echo -e "${WHT}  Installed models:${RST}"
for NUM in "${SELECTED_NUMS[@]}"; do
    NAME=$(get_field "$NUM" NAME); LABEL=$(get_field "$NUM" LABEL)
    if [ "$LABEL" = "UNCENSORED" ]; then TAG="${RED}[UNCENSORED]${RST}"
    else TAG="${CYN}[STANDARD]${RST}"; fi
    echo -e "${GRY}    - ${NAME} ${TAG}"
done
$HAS_CUSTOM && [ -n "$CUSTOM_URL" ] && echo -e "${GRY}    - Custom: ${CUSTOM_FILE} ${GRN}[CUSTOM]${RST}"

echo ""
echo -e "${WHT}  To start your AI: Double-click  Mac/start.command${RST}"
echo ""
read -n 1 -s -r -p "Press any key to close this installer..."
echo ""
