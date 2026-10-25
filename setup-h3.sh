#!/usr/bin/env bash
# GPUtw ephemeral GPU bootstrap: ComfyUI H3 + OpenH3-IR
# Run: bash setup-h3.sh
# Optional: MODEL_MODE=symlink bash setup-h3.sh
# Checked for Bash syntax; deployment on GPUtw requires running on that instance.
set -Eeuo pipefail

log() { printf '\n[H3 setup] %s\n' "$*"; }
die() { printf '\n[H3 setup ERROR] %s\n' "$*" >&2; exit 1; }
trap 'echo "[H3 setup ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

VAULT="${VAULT:-/vault}"
COMFY_DIR="${COMFY_DIR:-/workspace/comfyui-h3}"
COMFY_VERSION="${COMFY_VERSION:-v0.42.0}"
OPENH3_REPO="https://github.com/ruashots/ComfyUI-OpenH3-IR.git"
OPENH3_REF="${OPENH3_REF:-main}"
MODEL_MODE="${MODEL_MODE:-copy}"  # copy = fast local SSD; symlink = fast boot but slower model reads
PORT="${PORT:-8188}"
PYTHON="${PYTHON:-python3}"

[[ -d "${VAULT}/models" ]] || die "${VAULT}/models not found; verify your vault mount before running."
[[ -d /workspace ]] || die '/workspace not found.'
for executable in git "${PYTHON}"; do command -v "$executable" >/dev/null || die "Missing command: $executable"; done
[[ "$MODEL_MODE" == copy || "$MODEL_MODE" == symlink ]] || die 'MODEL_MODE must be copy or symlink.'
log "Vault: ${VAULT}; ComfyUI: ${COMFY_DIR}; model mode: ${MODEL_MODE}"

# Never replace an existing ComfyUI checkout without approval.
if [[ ! -f "${COMFY_DIR}/main.py" ]]; then
  if [[ -e "$COMFY_DIR" ]] && [[ -n "$(ls -A "$COMFY_DIR" 2>/dev/null)" ]]; then
    die "${COMFY_DIR} exists and is not an empty ComfyUI checkout; refusing to overwrite."
  fi
  log "Cloning ComfyUI ${COMFY_VERSION}"
  git clone --depth 1 --branch "$COMFY_VERSION" https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
else
  log 'ComfyUI already present; leaving checkout unchanged.'
  git -C "$COMFY_DIR" describe --tags --always 2>/dev/null || true
fi

# Fresh venv on each new GPU instance; reruns on the same instance reuse it.
if [[ ! -x "${COMFY_DIR}/.venv/bin/python" ]]; then
  log 'Creating Python virtual environment'
  "$PYTHON" -m venv "${COMFY_DIR}/.venv" || die 'python3 -m venv failed; install python3-venv for this Python version.'
fi
VENV_PYTHON="${COMFY_DIR}/.venv/bin/python"
if [[ ! -f "${COMFY_DIR}/.h3_requirements_installed" ]]; then
  log 'Installing PyTorch CUDA 13.0 and ComfyUI requirements (first run downloads packages)'
  "$VENV_PYTHON" -m pip install --upgrade pip
  "$VENV_PYTHON" -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130
  "$VENV_PYTHON" -m pip install -r "${COMFY_DIR}/requirements.txt"
  "$VENV_PYTHON" - <<'PY'
import torch
print('PyTorch:', torch.__version__, 'CUDA:', torch.version.cuda, 'GPU available:', torch.cuda.is_available())
if not torch.cuda.is_available():
    raise RuntimeError('GPU unavailable to PyTorch: check NVIDIA driver, container passthrough, and CUDA wheel')
print('GPU:', torch.cuda.get_device_name(0))
PY
  touch "${COMFY_DIR}/.h3_requirements_installed"
else
  log 'Existing Python environment detected; skipping dependency reinstall.'
fi

# MiniMax H3 model mapping. Keep source weights in Vault, place SSD copies or links in ComfyUI.
declare -a sources=()
declare -a targets=()
found_ref=0; found_encoder=0; found_video_vae=0; found_audio_vae=0
while IFS= read -r -d '' src; do
  file="$(basename "$src")"
  # Some Vault layouts mix different model classes under a single directory.
  case "$file" in
    *ref2va*.safetensors|*fl2va*.safetensors)
      dest_dir="diffusion_models"
      [[ "$file" == *ref2va* ]] && found_ref=1
      ;;
    qwen3vl*minimax*h3*.safetensors)
      dest_dir="text_encoders"; found_encoder=1 ;;
    minimax_h3_video_vae*.safetensors)
      dest_dir="vae"; found_video_vae=1 ;;
    minimax_h3_audio_vae*.safetensors)
      dest_dir="vae"; found_audio_vae=1 ;;
    *h3*turbo*.safetensors|*turbo*h3*.safetensors)
      dest_dir="loras" ;;
    *) continue ;;
  esac
  sources+=("$src")
  targets+=("${COMFY_DIR}/models/${dest_dir}/${file}")
done < <(find "${VAULT}/models" -type f -name '*.safetensors' -print0)

(( found_ref == 1 )) || die 'No H3 ref2va checkpoint found under /vault/models. Check actual Vault model layout.'
(( found_encoder == 1 )) || die 'No Qwen3-VL H3 text encoder found under /vault/models.'
(( found_video_vae == 1 )) || die 'No MiniMax H3 video VAE found under /vault/models.'
(( found_audio_vae == 1 )) || die 'No MiniMax H3 audio VAE found under /vault/models.'

# Check copy space ahead of copying, leaving 8 GiB for runtime/temp files.
if [[ "$MODEL_MODE" == copy ]]; then
  needed_bytes=0
  for i in "${!sources[@]}"; do
    src_size=$(stat -c '%s' "${sources[$i]}")
    if [[ ! -f "${targets[$i]}" ]] || [[ "$(stat -c '%s' "${targets[$i]}" 2>/dev/null || echo 0)" != "$src_size" ]]; then
      needed_bytes=$(( needed_bytes + src_size ))
    fi
  done
  free_bytes=$(df -B1 --output=avail /workspace | tail -n 1 | tr -d ' ')
  reserve=$(( 8 * 1024 * 1024 * 1024 ))
  if (( free_bytes < needed_bytes + reserve )); then
    die "Insufficient SSD for copying models + 8 GiB reserve. Need $(( (needed_bytes + reserve) / 1024 / 1024 / 1024 )) GiB, available $(( free_bytes / 1024 / 1024 / 1024 )) GiB. Re-run MODEL_MODE=symlink bash setup-h3.sh"
  fi
fi

log "Installing ${#sources[@]} H3 model file(s) into ComfyUI (${MODEL_MODE})"
for i in "${!sources[@]}"; do
  src="${sources[$i]}"; dest="${targets[$i]}"
  mkdir -p "$(dirname "$dest")"
  if [[ "$MODEL_MODE" == symlink ]]; then
    if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$src" ]]; then continue; fi
    if [[ -e "$dest" && ! -L "$dest" ]]; then
      log "Local file exists (will not replace): $dest"
      continue
    fi
    ln -sfn "$src" "$dest"
  else
    src_size=$(stat -c '%s' "$src")
    if [[ -f "$dest" ]] && [[ "$(stat -c '%s' "$dest")" == "$src_size" ]]; then continue; fi
    [[ ! -L "$dest" ]] || rm "$dest"
    log "Copying $(basename "$src") to SSD"
    tmp="${dest}.partial"
    rm -f "$tmp"
    cp "$src" "$tmp"
    mv -f "$tmp" "$dest"
  fi
done

# Install OpenH3-IR as an independent add-on, not by modifying H3 model internals.
NODE_DIR="${COMFY_DIR}/custom_nodes/ComfyUI-OpenH3-IR"
if [[ ! -d "$NODE_DIR/.git" ]]; then
  [[ ! -e "$NODE_DIR" ]] || die "${NODE_DIR} exists but is not a Git checkout; inspect before proceeding."
  log 'Cloning OpenH3-IR ComfyUI node pack'
  git clone "$OPENH3_REPO" "$NODE_DIR"
  if [[ "$OPENH3_REF" != main ]]; then git -C "$NODE_DIR" checkout "$OPENH3_REF"; fi
else
  log 'OpenH3-IR checkout already present; not updating automatically.'
fi
if [[ ! -f "${COMFY_DIR}/.openh3_requirements_installed" ]]; then
  log 'Installing OpenH3-IR Python requirements'
  "$VENV_PYTHON" -m pip install -r "${NODE_DIR}/requirements.txt"
  touch "${COMFY_DIR}/.openh3_requirements_installed"
fi

# Retain editable user data and rendered outputs across rentals.
USER_DIR="${VAULT}/comfyui-user-h3"
INPUT_DIR="${VAULT}/comfyui-input"
OUTPUT_DIR="${VAULT}/comfyui-output"
mkdir -p "$USER_DIR" "$INPUT_DIR" "$OUTPUT_DIR"

log 'Starting ComfyUI unless already running on the requested port'
if command -v curl >/dev/null && curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
  log "ComfyUI already serving port ${PORT}"
else
  cd "$COMFY_DIR"
  nohup "$VENV_PYTHON" main.py \
    --listen 0.0.0.0 --port "$PORT" --disable-auto-launch \
    --user-directory "$USER_DIR" \
    --input-directory "$INPUT_DIR" \
    --output-directory "$OUTPUT_DIR" \
    > "${COMFY_DIR}/comfyui.log" 2>&1 < /dev/null &
  echo $! > "${COMFY_DIR}/comfyui.pid"
fi

log "Startup launched. Check: tail -n 60 ${COMFY_DIR}/comfyui.log"
log "ComfyUI listening on port ${PORT} (use GPUtw's port mapping/proxy)."
log 'OpenH3-IR API endpoint and API key must be configured separately in its Setup node.'
