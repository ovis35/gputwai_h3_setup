#!/bin/bash
# Copy a verified local model file back over an unreadable /vault copy, then read it back and check SHA256.
# Usage: bash vault_repair.sh LOCAL_FILE VAULT_DIR SHA256
#   e.g. bash vault_repair.sh /workspace/comfyui-h3/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors #          /vault/models/text_encoders 35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6
set -u
log() { echo "$(date +%T) $*"; }
[ $# -eq 3 ] || { sed -n 2,5p "$0"; exit 1; }
SRC=$1
DIR=$2
SHA=$3
NAME=$(basename "$SRC")
PORT="${PORT:-8188}"
TMP=$DIR/.$NAME.repair.partial
DST=$DIR/$NAME

log "waiting for $PORT queue to be empty"
for i in $(seq 1 120); do
  n=$(curl -s localhost:$PORT/queue | python3 -c "import sys,json;q=json.load(sys.stdin);print(len(q['queue_running'])+len(q['queue_pending']))" 2>/dev/null || echo 1)
  [ "$n" = 0 ] && break
  sleep 15
done
[ "$n" = 0 ] || { log "QUEUE_STILL_BUSY"; echo REPAIR_FAIL; exit 1; }

log "copying to $TMP"
rm -f "$TMP"
timeout 1800 cp "$SRC" "$TMP" || { log "COPY_FAILED rc=$?"; rm -f "$TMP"; echo REPAIR_FAIL; exit 1; }
log "copied $(stat -c %s "$TMP") bytes"

log "verifying SHA256 read back from /vault"
got=$(timeout 1200 sha256sum "$TMP" | cut -d' ' -f1)
[ "$got" = "$SHA" ] || { log "SHA_MISMATCH got=$got"; rm -f "$TMP"; echo REPAIR_FAIL; exit 1; }
log "SHA OK"

log "replacing broken file"
timeout 120 mv -f "$TMP" "$DST" || { log "MV_FAILED rc=$?"; echo REPAIR_FAIL; exit 1; }
chmod 644 "$DST" 2>/dev/null
log "probe read head and tail"
sz=$(stat -c %s "$DST"); skip=$(( sz / 16777216 - 4 ))
timeout 60 dd if="$DST" of=/dev/null bs=16M count=4 status=none && \
timeout 60 dd if="$DST" of=/dev/null bs=16M skip=$skip count=4 status=none || { log "PROBE_FAILED"; echo REPAIR_FAIL; exit 1; }
ls -la "$DST"
echo REPAIR_DONE
