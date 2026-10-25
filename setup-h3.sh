#!/usr/bin/env bash
# GPUtw ephemeral GPU bootstrap: ComfyUI H3 + OpenH3-IR
# Run: bash setup-h3.sh
# Optional: MODEL_MODE=symlink bash setup-h3.sh
# Optional: HF_FALLBACK=0 bash setup-h3.sh  (fail instead of downloading unreadable Vault files from Hugging Face)
# Optional: MODEL_SOURCE=vault bash setup-h3.sh  (copy models from /vault instead of downloading them from Hugging Face)
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
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"  # seconds allowed to read the head and tail of each Vault model
HF_FALLBACK="${HF_FALLBACK:-1}"       # 1 = download unreadable Vault models from Hugging Face; 0 = abort
HF_REPO="${HF_REPO:-Comfy-Org/MiniMax-H3}"
MODEL_SOURCE="${MODEL_SOURCE:-auto}"    # auto = Hugging Face via aria2c when available, else /vault; hf; vault
HF_CONNECTIONS="${HF_CONNECTIONS:-16}"  # parallel connections per file for aria2c

[[ -d "${VAULT}/models" ]] || die "${VAULT}/models not found; verify your vault mount before running."
[[ -d /workspace ]] || die '/workspace not found.'
for executable in git "${PYTHON}"; do command -v "$executable" >/dev/null || die "Missing command: $executable"; done
[[ "$MODEL_MODE" == copy || "$MODEL_MODE" == symlink ]] || die 'MODEL_MODE must be copy or symlink.'
[[ "$HF_FALLBACK" == 0 || "$HF_FALLBACK" == 1 ]] || die 'HF_FALLBACK must be 0 or 1.'
[[ "$MODEL_SOURCE" == auto || "$MODEL_SOURCE" == hf || "$MODEL_SOURCE" == vault ]] || die 'MODEL_SOURCE must be auto, hf or vault.'

# /vault is a FUSE mount: a damaged file can list normally while every read blocks forever.
# Read 64 MiB from the head and tail in the background and give up after PROBE_TIMEOUT seconds.
# A plain `timeout dd` is not enough because a reader stuck in FUSE may never be reaped.
probe_readable() {
  local src=$1 size skip pid t
  size=$(stat -c '%s' "$src")
  skip=$(( size / 16777216 - 4 )); (( skip > 0 )) || skip=0
  ( dd if="$src" of=/dev/null bs=16M count=4 status=none &&
    dd if="$src" of=/dev/null bs=16M skip="$skip" count=4 status=none ) 2>/dev/null &
  pid=$!
  for (( t = 0; t < PROBE_TIMEOUT * 5; t++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; return; fi
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null || true
  disown "$pid" 2>/dev/null || true
  return 124
}

# Print "<sha256> <size>" for a file in the HF repo (path relative to the repo root); fail if not listed.
hf_meta() {
  local rel=$1
  command -v curl >/dev/null || return 1
  curl -fsS --max-time 60 --retry 3 "https://huggingface.co/api/models/${HF_REPO}/tree/main/$(dirname "$rel")" |
    "$PYTHON" -c '
import json, sys
for entry in json.load(sys.stdin):
    if entry.get("path") == sys.argv[1] and entry.get("lfs"):
        print(entry["lfs"]["oid"], entry["size"]); break
else:
    sys.exit(1)
' "$rel"
}

# aria2c splits one file over many connections; a single curl stream measured ~12 MB/s.
# Installing it takes seconds on the Ubuntu-based GPUtw images; without it we fall back to curl.
ensure_aria2() {
  command -v aria2c >/dev/null && return 0
  command -v apt-get >/dev/null || return 1
  log 'Installing aria2 for multi-connection downloads'
  { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2; } >/dev/null 2>&1 || true
  command -v aria2c >/dev/null
}

# Download a model from Hugging Face into its ComfyUI path (same relative path as the HF repo),
# resuming partial downloads, then verify SHA256 against the LFS oid. `hf download` stalled in
# testing, so this uses aria2c, or curl with a minimum speed so a dead connection is retried.
fetch_from_hf() {
  local dest=$1 rel meta expected_sha expected_size tmp have free attempt
  rel="${dest#"${COMFY_DIR}/models/"}"
  command -v curl >/dev/null || die "curl is required to download ${rel} from Hugging Face."
  meta=$(hf_meta "$rel") || die "${rel} is not listed in huggingface.co/${HF_REPO}; fix or re-upload the Vault copy manually."
  read -r expected_sha expected_size <<< "$meta"

  tmp="${dest}.hf.partial"
  have=$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)
  if (( have > expected_size )); then rm -f "$tmp"; have=0; fi
  free=$(df -B1 --output=avail "$(dirname "$dest")" | tail -n 1 | tr -d ' ')
  if (( free < expected_size - have + 8 * 1024 * 1024 * 1024 )); then
    die "Insufficient SSD to download ${rel} ($(( expected_size / 1024 / 1024 / 1024 )) GiB + 8 GiB reserve)."
  fi
  [[ ! -L "$dest" ]] || rm "$dest"

  log "Downloading ${rel} from huggingface.co/${HF_REPO} ($(( expected_size / 1024 / 1024 )) MiB)"
  for (( attempt = 1; attempt <= 5; attempt++ )); do
    have=$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)
    (( have < expected_size )) || break
    if command -v aria2c >/dev/null; then
      aria2c -x "$HF_CONNECTIONS" -s "$HF_CONNECTIONS" -k 16M --continue=true --file-allocation=none \
        --max-tries=10 --retry-wait=5 --lowest-speed-limit=1M --summary-interval=60 --console-log-level=warn \
        -d "$(dirname "$tmp")" -o "$(basename "$tmp")" "https://huggingface.co/${HF_REPO}/resolve/main/${rel}" && break
    else
      curl -fL -C - --retry 5 --speed-limit 1000000 --speed-time 60 \
        -o "$tmp" "https://huggingface.co/${HF_REPO}/resolve/main/${rel}" && break
    fi
    log "Download attempt ${attempt} for ${rel} failed; resuming"
  done
  have=$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)
  (( have == expected_size )) || die "Download of ${rel} incomplete (${have}/${expected_size} bytes). Re-run to resume."

  log "Verifying SHA256 of ${rel}"
  if [[ "$(sha256sum "$tmp" | cut -d ' ' -f 1)" != "$expected_sha" ]]; then
    rm -f "$tmp"
    die "SHA256 mismatch for ${rel}; deleted the download. Re-run to retry."
  fi
  mv -f "$tmp" "$dest"
}
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

# Runs in the background (see below), so it reports through its own log and exit status.
install_models() {
  local use_hf=0
  if [[ "$MODEL_MODE" == copy && "$MODEL_SOURCE" != vault ]]; then
    if ensure_aria2 || [[ "$MODEL_SOURCE" == hf ]]; then use_hf=1; fi
  fi
  if (( use_hf == 1 )); then log "Model source: huggingface.co/${HF_REPO} (vault for files HF does not list)"
  else log "Model source: ${VAULT}"; fi

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
    free_bytes=$(df -B1 --output=avail "$COMFY_DIR" | tail -n 1 | tr -d ' ')
    reserve=$(( 8 * 1024 * 1024 * 1024 ))
    if (( free_bytes < needed_bytes + reserve )); then
      die "Insufficient SSD for copying models + 8 GiB reserve. Need $(( (needed_bytes + reserve) / 1024 / 1024 / 1024 )) GiB, available $(( free_bytes / 1024 / 1024 / 1024 )) GiB. Re-run MODEL_MODE=symlink bash setup-h3.sh"
    fi
  fi

  log "Installing ${#sources[@]} H3 model file(s) into ComfyUI (${MODEL_MODE})"
  for i in "${!sources[@]}"; do
    src="${sources[$i]}"; dest="${targets[$i]}"
    mkdir -p "$(dirname "$dest")"
    # Local files never touch the Vault again, so check them before probing.
    if [[ "$MODEL_MODE" == symlink ]]; then
      if [[ -e "$dest" && ! -L "$dest" ]]; then
        log "Local file exists (will not replace): $dest"
        continue
      fi
    else
      src_size=$(stat -c '%s' "$src")
      if [[ -f "$dest" && ! -L "$dest" ]] && [[ "$(stat -c '%s' "$dest")" == "$src_size" ]]; then continue; fi
    fi
    # Prefer Hugging Face when it has the same file: multi-connection downloads beat /vault reads.
    if [[ "$MODEL_MODE" == copy && "$use_hf" == 1 ]] && hf_meta "${dest#"${COMFY_DIR}/models/"}" >/dev/null; then
      fetch_from_hf "$dest"
      continue
    fi
    if ! probe_readable "$src"; then
      printf '\n[H3 setup ERROR] Vault file is unreadable (read failed or timed out after %ss): %s\n' "$PROBE_TIMEOUT" "$src" >&2
      (( HF_FALLBACK == 1 )) || die "Fix or re-upload ${src}, or re-run with HF_FALLBACK=1 to download it from Hugging Face."
      fetch_from_hf "$dest"
      continue
    fi
    if [[ "$MODEL_MODE" == symlink ]]; then
      if [[ -L "$dest" ]] && [[ "$(readlink "$dest")" == "$src" ]]; then continue; fi
      ln -sfn "$src" "$dest"
    else
      [[ ! -L "$dest" ]] || rm "$dest"
      log "Copying $(basename "$src") to SSD"
      tmp="${dest}.partial"
      rm -f "$tmp"
      cp "$src" "$tmp"
      mv -f "$tmp" "$dest"
    fi
  done
}

# Models download in the background while Python dependencies install; both take minutes.
MODELS_LOG="${COMFY_DIR}/models-setup.log"
log "Fetching models in the background (log: ${MODELS_LOG})"
install_models > "$MODELS_LOG" 2>&1 &
models_pid=$!

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

log 'Waiting for model downloads to finish'
if ! wait "$models_pid"; then
  printf '\n[H3 setup ERROR] Model setup failed. Last 40 lines of %s:\n' "$MODELS_LOG" >&2
  tr '\r' '\n' < "$MODELS_LOG" | tail -n 40 >&2
  exit 1
fi
grep '^\[H3 setup\]' "$MODELS_LOG" | tail -n 20 || true
log 'Models ready'

# The OpenH3-IR LLM backend adds chat_template_kwargs for local inference servers.
# OpenAI's Chat Completions API rejects that non-standard argument with HTTP 400.
# Apply the previously verified, narrowly scoped fix on every bootstrap (idempotent).
log 'Checking OpenH3-IR OpenAI API compatibility patch'
"$VENV_PYTHON" - <<'PY'
from pathlib import Path
import py_compile
import h3ir.backend

path = Path(h3ir.backend.__file__)
source = path.read_text()
old = '        if not thinking:\n            # The ONLY spelling that works.'
new = ('        if not thinking and not self.base_url().startswith("https://api.openai.com/"):\n'
       '            # The ONLY spelling that works.')

if new in source:
    print('[H3 setup] OpenAI compatibility patch already present')
elif source.count(old) == 1:
    backup = path.with_suffix('.py.bak')
    if not backup.exists():
        backup.write_text(source)
    path.write_text(source.replace(old, new, 1))
    print('[H3 setup] Applied OpenAI compatibility patch to', path)
else:
    raise SystemExit(
        '[H3 setup ERROR] OpenH3-IR backend changed upstream: patch anchor not found '
        'uniquely. Refusing to continue until reviewed.'
    )

py_compile.compile(str(path), doraise=True)
PY

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

  # Same health check as `h3-ctl.sh restart`: fail loudly instead of leaving a dead server behind.
  command -v curl >/dev/null || die 'curl is required for the startup health check.'
  comfy_pid=$(cat "${COMFY_DIR}/comfyui.pid")
  deadline=$(( SECONDS + 120 ))
  until curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; do
    if ! kill -0 "$comfy_pid" 2>/dev/null || (( SECONDS >= deadline )); then
      printf '\n[H3 setup ERROR] ComfyUI (PID %s) did not come up on port %s. Last 40 log lines:\n' "$comfy_pid" "$PORT" >&2
      tr '\r' '\n' < "${COMFY_DIR}/comfyui.log" | tail -n 40 >&2
      exit 1
    fi
    sleep 2
  done
  log "PID ${comfy_pid}: ComfyUI is up on port ${PORT}"
fi

log "Logs: tail -n 60 ${COMFY_DIR}/comfyui.log; control: bash h3-ctl.sh status|restart|interrupt"
log "ComfyUI listening on port ${PORT} (use GPUtw's port mapping/proxy)."
log 'OpenH3-IR API endpoint and API key must be configured separately in its Setup node.'
