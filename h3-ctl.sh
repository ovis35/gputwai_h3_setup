#!/usr/bin/env bash
# Control the ComfyUI H3 server started by setup-h3.sh
# Run: bash h3-ctl.sh status | restart | interrupt
# Only touches the ComfyUI started with `main.py --port $PORT`; never the image's own ComfyUI on 8080.
set -Eeuo pipefail

log() { printf '\n[H3 ctl] %s\n' "$*"; }
die() { printf '\n[H3 ctl ERROR] %s\n' "$*" >&2; exit 1; }
trap 'echo "[H3 ctl ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

VAULT="${VAULT:-/vault}"
COMFY_DIR="${COMFY_DIR:-/workspace/comfyui-h3}"
PORT="${PORT:-8188}"
PYTHON="${PYTHON:-python3}"
VENV_PYTHON="${COMFY_DIR}/.venv/bin/python"
LOG_FILE="${COMFY_DIR}/comfyui.log"
PID_FILE="${COMFY_DIR}/comfyui.pid"
URL="http://127.0.0.1:${PORT}"

[[ "$PORT" != 8080 ]] || die "Port 8080 belongs to the image's own ComfyUI; refusing to touch it."
command -v curl >/dev/null || die 'Missing command: curl'

# Find ComfyUI by its argv elements rather than `pgrep -f`: a pattern match on the whole command
# line also matches (and with pkill, kills) any shell whose command string mentions main.py --port,
# including the ssh session running this script.
comfy_pids() {
  local dir pid k has_main port_ok
  local -a argv
  for dir in /proc/[0-9]*; do
    pid=${dir#/proc/}
    [[ "$pid" != "$$" && "$pid" != "$BASHPID" ]] || continue
    { mapfile -d '' -t argv < "${dir}/cmdline"; } 2>/dev/null || continue
    (( ${#argv[@]} >= 2 )) || continue
    [[ "${argv[0]##*/}" == python* ]] || continue
    has_main=0; port_ok=0
    for (( k = 1; k < ${#argv[@]}; k++ )); do
      [[ "${argv[k]}" == main.py || "${argv[k]}" == */main.py ]] && has_main=1
      [[ "${argv[k]}" == --port && "${argv[k + 1]:-}" == "$PORT" ]] && port_ok=1
      [[ "${argv[k]}" == "--port=${PORT}" ]] && port_ok=1
    done
    (( has_main && port_ok )) && echo "$pid"
  done
  return 0
}

log_tail() { tr '\r' '\n' < "$LOG_FILE" | grep -v '^[[:space:]]*$' | tail -n "$1"; }

# Keep start arguments, log and pid paths identical to setup-h3.sh.
start_comfyui() {
  [[ -x "$VENV_PYTHON" ]] || die "${VENV_PYTHON} not found; run setup-h3.sh first."
  mkdir -p "${VAULT}/comfyui-user-h3" "${VAULT}/comfyui-input" "${VAULT}/comfyui-output"
  log "Starting ComfyUI on port ${PORT}"
  (
    cd "$COMFY_DIR"
    nohup "$VENV_PYTHON" main.py \
      --listen 0.0.0.0 --port "$PORT" --disable-auto-launch \
      --user-directory "${VAULT}/comfyui-user-h3" \
      --input-directory "${VAULT}/comfyui-input" \
      --output-directory "${VAULT}/comfyui-output" \
      > "$LOG_FILE" 2>&1 < /dev/null &
    echo $! > "$PID_FILE"
  )
}

wait_healthy() {
  local comfy_pid deadline
  comfy_pid=$(cat "$PID_FILE")
  deadline=$(( SECONDS + 120 ))
  until curl -fsS --max-time 2 "${URL}/system_stats" >/dev/null 2>&1; do
    if ! kill -0 "$comfy_pid" 2>/dev/null || (( SECONDS >= deadline )); then
      printf '\n[H3 ctl ERROR] ComfyUI (PID %s) did not come up on port %s. Last 40 log lines:\n' "$comfy_pid" "$PORT" >&2
      tr '\r' '\n' < "$LOG_FILE" | tail -n 40 >&2
      exit 1
    fi
    sleep 2
  done
  log "PID ${comfy_pid}: ComfyUI is up on port ${PORT}"
}

cmd_status() {
  local -a pids
  local pid fuse_waiters ticks0 ticks1 hz
  mapfile -t pids < <(comfy_pids)

  log "ComfyUI process (port ${PORT})"
  if (( ${#pids[@]} == 0 )); then
    echo 'not running'
  else
    ps -o pid,etime,%cpu,rss,stat -p "$(IFS=,; echo "${pids[*]}")"
  fi

  log 'Queue'
  if curl -fsS --max-time 5 "${URL}/queue" 2>/dev/null | "$PYTHON" -c '
import json, sys
q = json.load(sys.stdin)
for name in ("queue_running", "queue_pending"):
    ids = [item[1] for item in q.get(name, [])]
    print(f"{name[6:]}: {len(ids)}", *ids)
'; then :; else echo "no response from ${URL}/queue"; fi

  log 'Last 5 log lines'
  if [[ -f "$LOG_FILE" ]]; then log_tail 5; else echo "${LOG_FILE} not found"; fi

  log 'GPU'
  if command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv
  else
    echo 'nvidia-smi not found'
  fi

  # Threads parked in request_wait_answer are waiting on the FUSE daemon (/vault). Combined
  # with no CPU use, that is the signature of a read on an unreadable Vault file.
  hz=$(getconf CLK_TCK)
  for pid in "${pids[@]}"; do
    fuse_waiters=$(cat /proc/"$pid"/task/*/wchan 2>/dev/null | grep -c '^request_wait_answer$' || true)
    ticks0=$(awk '{print $14 + $15}' /proc/"$pid"/stat 2>/dev/null || echo 0)
    sleep 1
    ticks1=$(awk '{print $14 + $15}' /proc/"$pid"/stat 2>/dev/null || echo 0)
    if (( fuse_waiters > 0 && ticks1 - ticks0 <= hz / 50 )); then
      log "WARNING: PID ${pid} has ${fuse_waiters} thread(s) waiting on FUSE (request_wait_answer) at ~0% CPU."
      echo 'Likely hung reading a /vault file. Copy models to local SSD (MODEL_MODE=copy) and run: bash h3-ctl.sh restart'
    elif (( fuse_waiters > 0 )); then
      echo "PID ${pid}: ${fuse_waiters} thread(s) in FUSE wait, CPU busy (probably a normal /vault read)."
    fi
  done
}

cmd_restart() {
  local -a pids
  local pid t alive
  mapfile -t pids < <(comfy_pids)
  if (( ${#pids[@]} > 0 )); then
    log "Stopping ComfyUI PID(s): ${pids[*]}"
    kill -TERM "${pids[@]}" 2>/dev/null || true
    for (( t = 0; t < 15; t++ )); do
      alive=0
      for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && { alive=1; break; }; done
      (( alive )) || break
      sleep 1
    done
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        log "PID ${pid} ignored SIGTERM for 15s; sending SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
  else
    log "No ComfyUI found on port ${PORT}"
  fi
  if curl -fsS --max-time 2 "${URL}/system_stats" >/dev/null 2>&1; then
    die "Port ${PORT} is still served by another process; inspect it before restarting."
  fi
  start_comfyui
  wait_healthy
}

cmd_interrupt() {
  curl -fsS --max-time 10 -X POST "${URL}/interrupt" >/dev/null || die "POST ${URL}/interrupt failed."
  log "Interrupt sent to ComfyUI on port ${PORT}"
}

case "${1:-}" in
  status) cmd_status ;;
  restart) cmd_restart ;;
  interrupt) cmd_interrupt ;;
  *) die 'Usage: bash h3-ctl.sh status | restart | interrupt' ;;
esac
