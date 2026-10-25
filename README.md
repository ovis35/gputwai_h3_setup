# GPUtw H3 setup

Bootstrap ComfyUI with MiniMax H3 and OpenH3-IR on a GPUtw instance, using models kept in `/vault/models`.

```bash
bash setup-h3.sh
```

The script installs ComfyUI, places the H3 models, starts ComfyUI on port 8188 and waits up to 120 s for it to answer `/system_stats`. If it does not come up, it prints the last 40 lines of `comfyui.log` and exits non-zero.

## Model mode

`MODEL_MODE=copy` is the default and recommended: models are copied from `/vault` to the local SSD once, and ComfyUI reads them locally.

`MODEL_MODE=symlink` boots faster but makes ComfyUI read every model from `/vault` (a FUSE mount) at load time. The first load of the 20 GB diffusion model took 5m32s that way, and an unreadable Vault file hangs ComfyUI indefinitely. Use it only when the SSD is too small to copy.

Before placing each model, the script reads its head and tail with a timeout. Files that fail are downloaded from `Comfy-Org/MiniMax-H3` on Hugging Face and checked against their SHA256 (`HF_FALLBACK=0` aborts instead).

## h3-ctl.sh

Control the ComfyUI started by `setup-h3.sh` (same `COMFY_DIR`, `VAULT`, `PORT` defaults):

```bash
bash h3-ctl.sh status     # PID, queue, last log lines, GPU memory, FUSE hang hint
bash h3-ctl.sh restart    # stop (TERM, then KILL after 15 s), start with setup-h3.sh's args, health check
bash h3-ctl.sh interrupt  # cancel the running prompt
```

`status` warns when ComfyUI threads are waiting on FUSE (`request_wait_answer`) at ~0% CPU, the sign of a read stuck on `/vault`. It only matches the process started with `main.py --port $PORT`, so it never touches the image's own ComfyUI on port 8080.
