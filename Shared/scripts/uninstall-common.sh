#!/bin/bash

set +e

PLATFORM="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USB_ROOT="$(dirname "$SHARED_DIR")"
MODELS_DIR="$SHARED_DIR/models"
BIN_DIR="$SHARED_DIR/bin"
INSTALLED_LIST="$MODELS_DIR/installed-models.txt"
LEGACY_MODELFILE="$MODELS_DIR/Modelfile"
OLLAMA_DATA="$MODELS_DIR/ollama_data"
OLLAMA_RUNTIME_SHARED="$SHARED_DIR/.ollama-runtime"
OLLAMA_RUNTIME_MODELS="$MODELS_DIR/.ollama-runtime"

if [ "$PLATFORM" = "linux" ]; then
  OLLAMA_BIN="$BIN_DIR/ollama-linux"
elif [ "$PLATFORM" = "mac" ]; then
  OLLAMA_BIN="$BIN_DIR/ollama-darwin"
else
  OLLAMA_BIN=""
fi

RED='\033[0;31m'
YLW='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
GRY='\033[0;37m'
DGR='\033[1;30m'
RST='\033[0m'

is_safe_path() {
  local target="$1"
  [ -n "$target" ] || return 1
  local abs_target
  abs_target="$(cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")"
  case "$abs_target" in
    "$SHARED_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_safe() {
  local p="$1"
  local label="$2"
  if [ ! -e "$p" ]; then
    echo -e "      ${DGR}Not found:${RST} $label"
    return 0
  fi
  if ! is_safe_path "$p"; then
    echo -e "      ${YLW}SKIPPED (outside Shared):${RST} $p"
    return 0
  fi
  rm -rf "$p" && echo -e "      ${GRN}Removed:${RST} $label" || echo -e "      ${RED}Failed:${RST} $label"
}

stop_engines() {
  pkill -f "ollama-windows|ollama-linux|ollama-darwin|ollama|llama-server-android" >/dev/null 2>&1
}

MODEL_COUNT=0
MODEL_LOCALS=()
MODEL_NAMES=()
MODEL_FILES=()
MODEL_MODELFILES=()

find_local_index() {
  local local_name="$1"
  local i=0
  while [ "$i" -lt "$MODEL_COUNT" ]; do
    if [ "${MODEL_LOCALS[$i]}" = "$local_name" ]; then
      echo "$i"
      return 0
    fi
    i=$((i + 1))
  done
  echo "-1"
}

gguf_from_modelfile() {
  local mf="$1"
  [ -f "$mf" ] || return 0
  local line
  line="$(head -n 1 "$mf" 2>/dev/null)"
  echo "$line" | sed -n 's/^[[:space:]]*FROM[[:space:]]\+\.\/\(.*\)[[:space:]]*$/\1/p'
}

add_or_update_model() {
  local local_name="$1"
  local display_name="$2"
  local gguf_file="$3"
  local mf_path="$4"
  [ -n "$local_name" ] || return 0

  local idx
  idx="$(find_local_index "$local_name")"
  if [ "$idx" -ge 0 ]; then
    [ -n "$display_name" ] && MODEL_NAMES[$idx]="$display_name"
    [ -n "$gguf_file" ] && MODEL_FILES[$idx]="$gguf_file"
    [ -n "$mf_path" ] && MODEL_MODELFILES[$idx]="$mf_path"
    return 0
  fi

  MODEL_LOCALS+=("$local_name")
  MODEL_NAMES+=("${display_name:-$local_name}")
  MODEL_FILES+=("$gguf_file")
  MODEL_MODELFILES+=("$mf_path")
  MODEL_COUNT=$((MODEL_COUNT + 1))
}

load_models() {
  MODEL_COUNT=0
  MODEL_LOCALS=()
  MODEL_NAMES=()
  MODEL_FILES=()
  MODEL_MODELFILES=()

  if [ -f "$INSTALLED_LIST" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local_name="$(echo "$line" | cut -d'|' -f1)"
      display_name="$(echo "$line" | cut -d'|' -f2)"
      mf_path="$MODELS_DIR/Modelfile-$local_name"
      gguf_file="$(gguf_from_modelfile "$mf_path")"
      add_or_update_model "$local_name" "$display_name" "$gguf_file" "$mf_path"
    done < "$INSTALLED_LIST"
  fi

  if [ -d "$MODELS_DIR" ]; then
    for mf_path in "$MODELS_DIR"/Modelfile-*; do
      [ -f "$mf_path" ] || continue
      base="$(basename "$mf_path")"
      local_name="${base#Modelfile-}"
      gguf_file="$(gguf_from_modelfile "$mf_path")"
      add_or_update_model "$local_name" "$local_name" "$gguf_file" "$mf_path"
    done
  fi
}

remove_ollama_aliases() {
  if [ -z "$OLLAMA_BIN" ] || [ ! -x "$OLLAMA_BIN" ]; then
    echo -e "      ${DGR}No Ollama binary for this platform. Skipping alias removal.${RST}"
    return 0
  fi
  if [ ! -d "$OLLAMA_DATA" ]; then
    echo -e "      ${DGR}No ollama_data found. Skipping alias removal.${RST}"
    return 0
  fi

  export OLLAMA_MODELS="$OLLAMA_DATA"
  export OLLAMA_HOST="127.0.0.1:11434"
  export OLLAMA_ORIGINS="*"
  export OLLAMA_HOME="$OLLAMA_RUNTIME_SHARED"
  export OLLAMA_RUNNERS_DIR="$OLLAMA_RUNTIME_SHARED/runners"
  export OLLAMA_TMPDIR="$OLLAMA_RUNTIME_SHARED/tmp"
  mkdir -p "$OLLAMA_RUNNERS_DIR" "$OLLAMA_TMPDIR"

  stop_engines
  sleep 1
  HOME="$OLLAMA_HOME" "$OLLAMA_BIN" serve >/dev/null 2>&1 &
  OLLAMA_PID=$!

  tries=0
  until curl -s "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      echo -e "      ${YLW}Could not start Ollama server. Skipping alias removal.${RST}"
      kill "$OLLAMA_PID" >/dev/null 2>&1
      stop_engines
      return 0
    fi
    sleep 1
  done

  for local_name in "$@"; do
    "$OLLAMA_BIN" rm "$local_name" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo -e "      ${GRN}Engine alias removed:${RST} $local_name"
    else
      echo -e "      ${DGR}Alias not found (skipped):${RST} $local_name"
    fi
  done

  kill "$OLLAMA_PID" >/dev/null 2>&1
  stop_engines
}

update_installed_list() {
  [ -f "$INSTALLED_LIST" ] || return 0
  tmp_file="$MODELS_DIR/.installed-models.tmp"
  : > "$tmp_file"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local_name="$(echo "$line" | cut -d'|' -f1)"
    keep=1
    for rm_local in "$@"; do
      [ "$local_name" = "$rm_local" ] && keep=0 && break
    done
    [ "$keep" -eq 1 ] && printf '%s\n' "$line" >> "$tmp_file"
  done < "$INSTALLED_LIST"

  if [ -s "$tmp_file" ]; then
    mv "$tmp_file" "$INSTALLED_LIST"
  else
    rm -f "$tmp_file"
    remove_safe "$INSTALLED_LIST" "models/installed-models.txt"
  fi
}

refresh_legacy_modelfile() {
  load_models
  if [ "$MODEL_COUNT" -gt 0 ]; then
    first_mf="${MODEL_MODELFILES[0]}"
    if [ -f "$first_mf" ]; then
      cp "$first_mf" "$LEGACY_MODELFILE"
      echo -e "      ${DGR}Updated legacy Modelfile to:${RST} ${MODEL_LOCALS[0]}"
      return 0
    fi
  fi
  remove_safe "$LEGACY_MODELFILE" "models/Modelfile"
}

remove_selected_models() {
  locals_to_remove=("$@")
  [ "${#locals_to_remove[@]}" -gt 0 ] || return 0

  remove_ollama_aliases "${locals_to_remove[@]}"

  for rm_local in "${locals_to_remove[@]}"; do
    idx="$(find_local_index "$rm_local")"
    [ "$idx" -ge 0 ] || continue

    gguf="${MODEL_FILES[$idx]}"
    mf_path="${MODEL_MODELFILES[$idx]}"

    if [ -n "$gguf" ]; then
      remove_safe "$MODELS_DIR/$gguf" "models/$gguf"
    fi
    if [ -n "$mf_path" ]; then
      remove_safe "$mf_path" "models/$(basename "$mf_path")"
    fi
  done

  update_installed_list "${locals_to_remove[@]}"
  refresh_legacy_modelfile

  load_models
  if [ "$MODEL_COUNT" -eq 0 ]; then
    remove_safe "$OLLAMA_DATA" "models/ollama_data"
    remove_safe "$OLLAMA_RUNTIME_SHARED" ".ollama-runtime"
    remove_safe "$OLLAMA_RUNTIME_MODELS" "models/.ollama-runtime"
  fi
}

remove_all_downloaded() {
  echo ""
  echo -e "${YLW}[2/2] Removing downloaded files (keeping base files)...${RST}"
  stop_engines

  if [ -d "$MODELS_DIR" ]; then
    for gguf in "$MODELS_DIR"/*.gguf; do
      [ -f "$gguf" ] || continue
      remove_safe "$gguf" "models/$(basename "$gguf")"
    done
    for mf in "$MODELS_DIR"/Modelfile*; do
      [ -f "$mf" ] || continue
      remove_safe "$mf" "models/$(basename "$mf")"
    done
  fi

  remove_safe "$INSTALLED_LIST" "models/installed-models.txt"
  remove_safe "$OLLAMA_DATA" "models/ollama_data"
  remove_safe "$OLLAMA_RUNTIME_SHARED" ".ollama-runtime"
  remove_safe "$OLLAMA_RUNTIME_MODELS" "models/.ollama-runtime"

  remove_safe "$BIN_DIR/ollama-windows.exe" "bin/ollama-windows.exe"
  remove_safe "$BIN_DIR/ollama-linux" "bin/ollama-linux"
  remove_safe "$BIN_DIR/ollama-darwin" "bin/ollama-darwin"
  remove_safe "$BIN_DIR/llama-server-android" "bin/llama-server-android"
  remove_safe "$BIN_DIR/llama.cpp" "bin/llama.cpp"
  remove_safe "$BIN_DIR/temp_ollama" "bin/temp_ollama"
  remove_safe "$SHARED_DIR/llama-server.log" "llama-server.log"
  remove_safe "$SHARED_DIR/__pycache__" "__pycache__"
  remove_safe "$SHARED_DIR/python-embed.zip" "python-embed.zip"
  remove_safe "$SHARED_DIR/python" "python"
  remove_safe "$SHARED_DIR/chat_data" "chat_data"
}

run_model_remover_menu() {
  echo ""
  echo -e "${YLW}[1/2] Remove selected model(s)${RST}"
  load_models

  if [ "$MODEL_COUNT" -eq 0 ]; then
    echo -e "      ${YLW}No installed models found.${RST}"
    return 0
  fi

  echo ""
  echo -e "${GRY}Installed models:${RST}"
  i=0
  while [ "$i" -lt "$MODEL_COUNT" ]; do
    gguf="${MODEL_FILES[$i]}"
    [ -n "$gguf" ] || gguf="unknown"
    echo -e "  [$((i + 1))] ${MODEL_NAMES[$i]} (${MODEL_LOCALS[$i]}) -> $gguf"
    i=$((i + 1))
  done

  echo ""
  echo "Select removal mode:"
  echo "  [1] One model"
  echo "  [2] Many models"
  echo "  [3] All models"
  echo "  [Q] Cancel"
  read -r -p "Mode: " mode
  mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"

  selected_locals=()
  case "$mode" in
    1)
      read -r -p "Enter model number: " one_num
      if [[ "$one_num" =~ ^[0-9]+$ ]] && [ "$one_num" -ge 1 ] && [ "$one_num" -le "$MODEL_COUNT" ]; then
        selected_locals+=("${MODEL_LOCALS[$((one_num - 1))]}")
      fi
      ;;
    2)
      read -r -p "Enter model numbers (comma separated, e.g. 1,3,4): " many_raw
      IFS=',' read -r -a many_tokens <<< "$many_raw"
      for tok in "${many_tokens[@]}"; do
        num="$(echo "$tok" | tr -d ' ')"
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$MODEL_COUNT" ]; then
          local_name="${MODEL_LOCALS[$((num - 1))]}"
          already=0
          for s in "${selected_locals[@]}"; do
            [ "$s" = "$local_name" ] && already=1 && break
          done
          [ "$already" -eq 0 ] && selected_locals+=("$local_name")
        fi
      done
      ;;
    3)
      i=0
      while [ "$i" -lt "$MODEL_COUNT" ]; do
        selected_locals+=("${MODEL_LOCALS[$i]}")
        i=$((i + 1))
      done
      ;;
    *)
      echo -e "      ${YLW}Cancelled.${RST}"
      return 0
      ;;
  esac

  if [ "${#selected_locals[@]}" -eq 0 ]; then
    echo -e "      ${YLW}Nothing selected.${RST}"
    return 0
  fi

  remove_selected_models "${selected_locals[@]}"
}

echo ""
echo -e "${CYN}==========================================================${RST}"
echo -e "${CYN}   PORTABLE AI UNINSTALLER (${PLATFORM})${RST}"
echo -e "${CYN}==========================================================${RST}"
echo ""
echo "  [1] Remove selected model(s) (one / many / all)"
echo "  [2] Remove all downloaded files (except base files)"
echo "  [Q] Quit"
echo ""
read -r -p "Your choice: " choice
choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]')"

case "$choice" in
  1) run_model_remover_menu ;;
  2) remove_all_downloaded ;;
  *)
    echo ""
    echo -e "${YLW}Uninstall cancelled.${RST}"
    exit 0
    ;;
esac

echo ""
echo -e "${CYN}==========================================================${RST}"
echo -e "${GRN}   UNINSTALL COMPLETE${RST}"
echo -e "${CYN}==========================================================${RST}"
echo ""
