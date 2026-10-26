# GPUtw H3 setup

## 這是什麼

在 GPUtw 的臨時 GPU 執行個體上，一行指令架好 ComfyUI `v0.42.0` + [OpenH3-IR](https://github.com/ruashots/ComfyUI-OpenH3-IR)，用 `/vault/models` 裡的模型跑 MiniMax H3 Ref2VA，服務開在 port `8188`。映像檔內建、跑在 port `8080` 的 ComfyUI 完全不碰。執行個體關掉後 `/workspace` 會消失，所以每次租新機器都重跑 `setup-h3.sh`。使用者資料、輸入和輸出放在 `/vault`，跨租期保留。

## 需求

- 已掛載 `/vault` 的 GPUtw 執行個體，以及本機 SSD `/workspace`
- `git`、`python3`、`curl`
  - Python 3.10 可以用，但 ComfyUI 會警告 3.10 在 2026-10-31 EOL。要換版本就用 `PYTHON=python3.12 bash setup-h3.sh`。
- `/vault/models` 底下（任何子目錄都行）要有下列模型。腳本會依檔名比對，**符合的檔案全部都會放進 ComfyUI**，所以 Vault 裡放了幾個版本就會複製幾個。

| 用途 | 檔名比對規則 | 放到 | 實測用的檔案 | 必要 |
|---|---|---|---|---|
| Ref2VA diffusion model | `*ref2va*.safetensors` | `models/diffusion_models` | `minimax_h3_ref2va_pruned_int8_convrot.safetensors` | 是 |
| FL2VA diffusion model | `*fl2va*.safetensors` | `models/diffusion_models` | — | 否 |
| Text encoder | `qwen3vl*minimax*h3*.safetensors` | `models/text_encoders` | `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | 是 |
| Video VAE | `minimax_h3_video_vae*.safetensors` | `models/vae` | `minimax_h3_video_vae_*.safetensors` | 是 |
| Audio VAE | `minimax_h3_audio_vae*.safetensors` | `models/vae` | `minimax_h3_audio_vae_fp32.safetensors` | 是 |
| Turbo LoRA | `*h3*turbo*.safetensors` 或 `*turbo*h3*.safetensors` | `models/loras` | — | 否 |

缺少任何一個「必要」項目，腳本會直接報錯停止。

## 快速開始

1. SSH 進執行個體：

   ```bash
   ssh -i ~/.ssh/<key> -p 2222 pod-<instance-id>@ssh.gputw.ai
   ```

2. 把 `setup-h3.sh` 放上去（`h3-ctl.sh` 也建議一起放），然後執行：

   ```bash
   bash setup-h3.sh
   ```

   第一次會安裝 PyTorch（CUDA 13.0）和相依套件，同時在背景把模型下載或複製到 SSD（進度在 `$COMFY_DIR/models-setup.log`），兩邊都完成後啟動 ComfyUI，並等它回應 `/system_stats`，最多等 120 秒。沒起來的話會印出 `comfyui.log` 最後 40 行並以非零碼結束。重跑是安全的：已完成的步驟會跳過。

3. 在 GPUtw 主控台開放 HTTP port `8188`，用 GPUtw 給的網址開 ComfyUI。

4. OpenH3-IR 的 LLM endpoint 和 API key 要在 workflow 的 OpenH3-IR **Setup** node 裡設定，腳本不處理金鑰。

## 環境變數

| 變數 | 預設值 | 使用者 | 說明 |
|---|---|---|---|
| `VAULT` | `/vault` | 兩者 | Vault 掛載點。模型在 `$VAULT/models`；使用者資料、輸入、輸出在 `$VAULT/comfyui-user-h3`、`$VAULT/comfyui-input`、`$VAULT/comfyui-output` |
| `COMFY_DIR` | `/workspace/comfyui-h3` | 兩者 | ComfyUI 安裝位置，`comfyui.log`、`comfyui.pid` 和 `.venv` 都在這裡 |
| `PORT` | `8188` | 兩者 | ComfyUI 監聽的 port。`h3-ctl.sh` 拒絕 `8080` |
| `PYTHON` | `python3` | 兩者 | 用來建 venv（`setup-h3.sh`），以及解析 API 回應（`h3-ctl.sh status`） |
| `COMFY_VERSION` | `v0.42.0` | `setup-h3.sh` | clone 的 ComfyUI tag |
| `OPENH3_REF` | `main` | `setup-h3.sh` | OpenH3-IR 要 checkout 的 ref |
| `MODEL_MODE` | `copy` | `setup-h3.sh` | `copy`：複製到本機 SSD；`symlink`：建連結，直接從 `/vault` 讀。見下方〈MODEL_MODE〉 |
| `PROBE_TIMEOUT` | `30` | `setup-h3.sh` | 每個 Vault 模型讀取探測（開頭和結尾各 64 MiB）的逾時秒數 |
| `HF_FALLBACK` | `1` | `setup-h3.sh` | `1`：探測失敗的檔案改從 Hugging Face 下載並比對 SHA256；`0`：直接報錯停止 |
| `HF_REPO` | `Comfy-Org/MiniMax-H3` | `setup-h3.sh` | 模型下載和備援用的 Hugging Face repo |
| `MODEL_SOURCE` | `vault` | `setup-h3.sh` | `copy` 模式下模型從哪裡來。`vault`：從 `/vault` 複製；`hf`：從 Hugging Face 下載（有 `aria2c` 就用，沒有就用 `curl`），比對 SHA256；`auto`：裝得起 `aria2c` 就用 `hf`，否則 `vault`。HF 上沒有的檔案（例如自訂 LoRA）一律從 `/vault` 複製 |
| `HF_CONNECTIONS` | `16` | `setup-h3.sh` | `aria2c` 每個檔案同時開幾條連線 |

範例：

```bash
MODEL_MODE=symlink PYTHON=python3.12 bash setup-h3.sh
```

## h3-ctl.sh

管理 `setup-h3.sh` 啟動的 ComfyUI，使用相同的 `VAULT`、`COMFY_DIR`、`PORT`、`PYTHON` 預設值。

```bash
bash h3-ctl.sh status
```

`status` 會顯示：

- ComfyUI 程序的 PID、執行時間、CPU、RSS
- `/queue` 的執行中和等待中 prompt 數量與 id
- `comfyui.log` 最後 5 行（`\r` 轉成換行，看得到 tqdm 進度）
- `nvidia-smi` 的 GPU 記憶體用量、總量、使用率
- 卡死提示：如果有 thread 停在 FUSE 的 `request_wait_answer`，而且 CPU 約 0%，會警告「很可能卡在讀 `/vault` 檔案」

```bash
bash h3-ctl.sh restart
```

`restart` 先送 SIGTERM，15 秒內沒結束就送 SIGKILL。接著用和 `setup-h3.sh` 完全相同的參數、log 和 pid 路徑重新啟動，並跑同一套 120 秒健康檢查。

```bash
bash h3-ctl.sh interrupt
```

`interrupt` 送出 `POST /interrupt`，取消目前執行中的 prompt。

找程序的方式是逐一比對 `/proc/*/cmdline` 的參數（python + `main.py` + `--port $PORT`），不用 `pgrep -f`，所以不會誤認呼叫它的 ssh shell，也不會碰到 port `8080` 的 ComfyUI。

## MODEL_MODE

**`copy` 是預設也是建議值。** 模型從 `/vault` 複製到本機 SSD 一次，之後 ComfyUI 都從 SSD 讀。複製前會先檢查空間，要求「待複製大小 + 8 GiB」的剩餘空間，不夠就停下並建議改用 symlink。

`symlink` 開機比較快，但 ComfyUI 每次載入模型都要經過 `/vault`（SeaweedFS FUSE）讀取：

- 2026-10-25 實測，20 GB 的 diffusion model 第一次載入花了 5 分 32 秒。
- `/vault` 上只要有一個檔案讀不到，ComfyUI 就會無限期卡住（見〈疑難排解〉）。

只有 SSD 放不下時才用 `symlink`。

`copy` 模式下，模型預設從 `/vault` 複製（`MODEL_SOURCE=vault`），在背景進行，同時前景安裝 Python 套件。2026-10-26 在 RTX 5090 上實測：`/vault` 讀取約 35–42 MB/s，42 GB 模型約 20 分鐘；套件安裝約 7 分鐘，跟複製同時進行，開機到 ComfyUI 起來共約 21 分鐘。同一天 `aria2c` 開 16 條連線從 Hugging Face 下載，總速度只有約 10 MB/s（每條不到 1 MB/s，HF CDN 看起來是限制整台機器的總流量），所以 HF 只在 `/vault` 有問題時才用：`MODEL_SOURCE=hf`，或讀取探測失敗時的 `HF_FALLBACK`。

從 `/vault` 複製或建連結之前，都會先對每個 Vault 檔案做讀取探測。探測失敗時：`HF_FALLBACK=1` 就從 Hugging Face 下載到 ComfyUI 的 models 目錄，並比對 LFS 的 SHA256；`HF_FALLBACK=0` 就印出檔名並停止。

## 實測數據

環境：RTX 5090 32 GB，2026-10-25。模型為 `minimax_h3_ref2va_pruned_int8_convrot` 加 `qwen3vl_32b_minimax_h3_nvfp4_awq` text encoder。設定為 768×1344（9:16）、20 steps、beta scheduler、sizing max。

| 測試 | 總時間 | 細項 |
|---|---|---|
| 5.875 秒 / 141 frames，冷啟動（模型經 `/vault` symlink） | 19 分 17 秒 | diffusion model 第一次載入 5 分 32 秒；取樣約 23 秒/step（約 7.5 分鐘）；VAE decode 約 6 分鐘；VRAM 約 31.7 GB，GPU 使用率 100% |
| 同上，熱啟動（第二次執行，換 seed） | 8 分 01 秒 | 第一個 step 22 秒 |
| 15.084 秒 / 362 frames，冷啟動（模型經 `/vault` symlink，page cache 已被清掉） | 1 小時 04 分 51 秒 | 提示詞編譯約 1.5 分鐘；diffusion model 載入約 22 分鐘（`/vault` 讀取只有 9–11 MB/s）；取樣約 107.6 秒/step（20 steps 約 34 分鐘，是 5.875 秒的約 4.7 倍）；VAE decode 約 6.5 分鐘；VRAM 峰值約 31.8 / 32.6 GB，沒有 OOM，GPU 使用率 100% |

15 秒那次的載入時間主要卡在 `/vault`：同一台機器剛把 15.7 GB 寫回 `/vault` 又讀回比對，page cache 被擠掉，而 `/vault` 當下讀取很慢。模型在本機 SSD（`MODEL_MODE=copy`）且已載入時，同樣設定一支 15 秒估計約 42 分鐘（編譯 + 取樣 + decode），這個數字是推算，還沒實測。

下載與寫入：

| 項目 | 數據 |
|---|---|
| Hugging Face 下載（`curl`） | 約 12 MB/s，15.7 GB 約 22 分鐘 |
| Hugging Face 下載（`hf download`） | 卡在約 266 MB 不動 |
| 寫回 `/vault`（15.7 GB） | 約 18 分鐘；25–40 MB/s，接近結尾掉到約 3 MB/s |
| 寫回後讀回比對 SHA256 | 約 7.5 分鐘 |

## 疑難排解

### 卡在 `Model storage policy ... text_encoders/qwen3vl...`，CPU/GPU 都是 0%

**症狀**：log 停在 `Model storage policy ... text_encoders/qwen3vl...` 好幾分鐘沒有新輸出，CPU 和 GPU 使用率都是 0%。

**原因**：`/vault` 上的檔案讀不到。`/vault` 是 SeaweedFS FUSE 掛載，損壞的檔案可以正常列出、大小也對，但任何讀取都會永遠卡住，thread 停在 `request_wait_answer`。

**處理**：
- `/interrupt` 沒用，必須重啟 ComfyUI：`bash h3-ctl.sh restart`。
- `bash h3-ctl.sh status` 會顯示 FUSE 等待的警告。
- 現在的 `setup-h3.sh` 會先做讀取探測，搭配 `HF_FALLBACK=1` 會自動改從 Hugging Face 下載，所以用 `copy` 模式重跑 `setup-h3.sh` 通常就能解決。

### 驗證模型檔是否完整

比對大小和 SHA256。正確值在 Hugging Face API 的 `lfs.oid` 欄位：

```bash
curl -s https://huggingface.co/api/models/Comfy-Org/MiniMax-H3/tree/main/text_encoders
sha256sum /vault/models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
```

已知正確值：`qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` 為 15,687,142,551 bytes，SHA256 `35a88d51044231fe332301d7a62aa81e3f2cba62febeb446e2c1e3e0ef76f2c6`。`/vault` 上的這個檔案已在 2026-10-25 修復。

如果檔案本身讀不到，`sha256sum` 也會卡住。可以先用 `timeout 30 dd if=<檔案> of=/dev/null bs=16M count=4` 測試能不能讀。

### Workflow 只產生文字、沒有影片

SaveVideo node 被 mute 了，所以 Render subgraph 不會執行。這時只會跑 prompt 編譯，大約 48 秒就結束，沒有影片輸出。把 SaveVideo 取消 mute 即可。

### `pkill -f` / `pgrep -f` 把自己的 ssh 連線砍掉

如果 `pkill -f` 或 `pgrep -f` 的 pattern 也出現在你的 ssh 命令列裡（例如 `ssh ... "pkill -f 'main.py --port 8188'"`），會連 ssh shell 本身一起符合，甚至被殺掉。請改用 `bash h3-ctl.sh restart`，或依 PID 操作（`cat /workspace/comfyui-h3/comfyui.pid`）。

## 模型來源

模型來自 Hugging Face 的 [Comfy-Org/MiniMax-H3](https://huggingface.co/Comfy-Org/MiniMax-H3)，不需要申請存取。授權依 [MiniMax H3 Community License](https://huggingface.co/MiniMaxAI/MiniMax-H3)。
