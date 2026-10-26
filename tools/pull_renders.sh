#!/usr/bin/env bash
# Runs detached on your PC: every 30s, download each finished render from the pod into DEST and verify it
# by checksum; stop once no render in the given manifests is running or pending. Log: DEST/_pull.log
# Usage: POD_HOST=pod-xxxx@ssh.gputw.ai bash pull_renders.sh DEST /vault/h3-batch/A.json [/vault/h3-batch/B.json ...]
# Optional: SSH_KEY (default ~/.ssh/gputw_ed25519), SSH_PORT (2222), REMOTE_DIR (where h3-batch.py lives on the pod)
set -u
[[ $# -ge 2 && -n "${POD_HOST:-}" ]] || { sed -n 2,5p "$0"; exit 1; }
K="-i ${SSH_KEY:-$HOME/.ssh/gputw_ed25519} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20"
P="${SSH_PORT:-2222}"
H="$POD_HOST"
R="${REMOTE_DIR:-/workspace/gputwai_h3_setup}"
D="$1"; shift
MANIFESTS="$*"
LOG="$D/_pull.log"
LIST="$D/_done.md5"
mkdir -p "$D"

while :; do
  ssh $K -p "$P" "$H" "cd $R && for m in $MANIFESTS; do python3 h3-batch.py status \$m; done | awk '/render/ && /success/ {print \$NF}' | sort -u | while read p; do f=\$(ls /vault/comfyui-output/\$p*.mp4 2>/dev/null | head -1); [ -n \"\$f\" ] && md5sum \"\$f\"; done" 2>/dev/null > "$LIST"
  while read -r sum path; do
    f=$(basename "$path")
    [ "$(md5sum "${D:?}/${f:?}" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] && continue
    scp -q $K -P "$P" "$H:$path" "${D:?}/" 2>/dev/null
    if [ "$(md5sum "${D:?}/${f:?}" | cut -d' ' -f1)" = "$sum" ]; then
      echo "$(date +%T) downloaded+verified $f" >> "$LOG"
    else
      rm -f "${D:?}/${f:?}"; echo "$(date +%T) checksum mismatch, will retry $f" >> "$LOG"
    fi
  done < "$LIST"
  left=$(ssh $K -p "$P" "$H" "cd $R && for m in $MANIFESTS; do python3 h3-batch.py status \$m; done | grep render | grep -c -E 'running|pending'" 2>/dev/null)
  echo "$(date +%T) renders left: ${left:-?}" >> "$LOG"
  [ "$left" = 0 ] && { echo "$(date +%T) ALL_DONE" >> "$LOG"; break; }
  sleep 30
done
