# 用 Docker 執行 jt-live-whisper（伺服器版）

這個映像把 jt-live-whisper 的安裝流程（`install.sh --server`）包進 Ubuntu 24.04 +
Python 3.12 的容器裡，適合在 Linux 主機上以 WebUI 常駐，或用命令列批次處理音訊檔。

> 本映像由社群貢獻，非官方發行版。安裝邏輯沿用專案自己的 `install.sh`，
> 升級只要重建映像即可。

## 容器裡能用 / 不能用

| 功能 | 容器內 | 說明 |
|---|---|---|
| 離線音檔批次處理 | ✅ | WebUI 上傳或 `./start.sh --input`，支援 mp3/wav/m4a/flac 等 |
| WebUI（瀏覽器介面） | ✅ | 預設埠 19781 |
| 講者辨識、會議摘要 | ✅ | 摘要需另接 LLM 伺服器（Ollama 等） |
| **即時系統音訊字幕/翻譯** | ✅（Linux，需掛 socket） | 把主機的 PipeWire/PulseAudio socket 掛進容器即可（見「即時系統音訊」） |
| 懸浮字幕（PySide/PyQt 視窗） | ❌ | 需要圖形桌面，伺服器版不含 |
| GPU 加速 | ⚠️ 需 CUDA 版建置 | 預設為 CPU 版；以 cu124 建置並用 `--gpus all` 執行即可 GPU 加速（見下） |

即時模式擷取的是「執行 jt-live-whisper 那台機器正在播放的聲音」。容器裡要做這件事，
必須把主機的 PipeWire/PulseAudio socket 掛進來（見下），讓容器內的 `parec`／`pactl`
連到主機的音訊伺服器、抓預設喇叭的 `.monitor`。沒掛 socket 時即時模式才不可用。

## 快速開始

先建置映像（第一次約 15～20 分鐘，會下載 PyTorch 與所有地端 AI 模型約 4～5 GB）：

```bash
docker build -t jt-live-whisper .
```

執行（單機使用，用 `--network host`）：

```bash
docker run -d --name jt-live-whisper \
  --network host \
  -v jtlw-data:/data \
  jt-live-whisper
```

瀏覽器開啟 <http://localhost:19781>。

> **為什麼用 `--network host`？** WebUI 依「連線來源」判斷權限：來自 `127.0.0.1` 視為本機（完整權限），
> 其他來源只給唯讀（沒設密碼時顯示「唯讀模式 / 等待主機開始辨識...」）。用 `-p` 發布埠時，連線經過
> Docker NAT，容器看到的是 bridge 閘道（如 `172.17.0.1`）而不是 `127.0.0.1`，本機瀏覽器也會被當成遠端。
> `--network host`（Linux）讓連線真的來自 `127.0.0.1`，本機才能用完整功能。

## 使用 docker compose

```bash
docker compose up -d --build
```

`docker-compose.yml` 已預設好埠、volume 與環境變數，可直接修改。

## 資料持久化（volumes）

| 容器路徑 | 內容 | 建議 |
|---|---|---|
| `/data` | `config.json`、`recordings/`（上傳與錄音）、`logs/`（逐字稿與摘要） | 一定要掛，否則重啟會遺失 |
| `/root/.cache/huggingface` | Whisper 等模型快取 | 選配；映像已烘入模型，掛了可避免升級容器時重新下載 |
| `/root/.local/share` | NLLB 等離線模型 | 選配，同上 |

進入點會把 `config.json`、`recordings/`、`logs/` 連到 `/data`，設定與產出都會保存。

## 環境變數

| 變數 | 用途 |
|---|---|
| `JTLW_WEBUI_ALLOWED_IPS` | 可連線的來源網段（逗號分隔、支援 CIDR）。留空＝不限制；本機一律放行 |
| `JTLW_WEBUI_READ_PASSWORD` | 首次啟動時設定 WebUI 唯讀密碼（只存 sha256） |
| `JTLW_WEBUI_ADMIN_PASSWORD` | 首次啟動時設定 WebUI 管理密碼 |
| `JTLW_DATA_DIR` | 持久化目錄，預設 `/data` |

## 權限與安全性

WebUI 依「連線來源」決定角色：

| 來源 | 沒設密碼 | 設了唯讀密碼 | 設了管理密碼 |
|---|---|---|---|
| 本機（`127.0.0.1`） | 完整權限 | 完整權限 | 完整權限 |
| 其他（遠端） | **唯讀**（顯示「唯讀模式 / 等待主機開始辨識...」） | 需唯讀密碼才能觀看 | 可用管理密碼取得完整權限 |

- **單機使用**：用 `--network host`（見上），localhost 即本機，不需密碼。
- **要讓區網其他電腦連線**：遠端預設只有唯讀，需設定密碼（與來源限制），例如：

```bash
docker run -d --name jt-live-whisper --network host \
  -e JTLW_WEBUI_ALLOWED_IPS=192.168.1.0/24 \
  -e JTLW_WEBUI_READ_PASSWORD=change-me \
  -e JTLW_WEBUI_ADMIN_PASSWORD=change-me \
  -v jtlw-data:/data \
  jt-live-whisper
```

WebUI 綁 `0.0.0.0`，`--network host` 會讓它聽在主機所有介面；沒設密碼時區網任何人都能
唯讀觀看。請搭配 `JTLW_WEBUI_ALLOWED_IPS` 或密碼限制。

## 即時系統音訊（Linux）

把主機的 PipeWire/PulseAudio socket、cookie 與執行期目錄掛進容器，容器內的 `parec`
就能抓到主機預設喇叭的 `.monitor`（也就是電腦正在播的聲音）：

```bash
docker run -d --name jt-live-whisper --network host --gpus all \
  -e XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  -e PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native" \
  -v "$XDG_RUNTIME_DIR/pulse:$XDG_RUNTIME_DIR/pulse" \
  -v "$HOME/.config/pulse/cookie:/root/.config/pulse/cookie:ro" \
  -v jtlw-data:/data \
  jt-live-whisper:cuda
```

（`docker-compose.yml` 已含這幾行，`docker compose up -d` 即生效。）

驗證容器內看得到主機的裝置：

```bash
docker exec jt-live-whisper pactl info
docker exec jt-live-whisper pactl list short sources | grep monitor
docker exec jt-live-whisper ./start.sh --list-devices
```

之後用終端機跑即時字幕（例：英翻中）：

```bash
docker run -it --rm --network host --gpus all \
  -e XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" -e PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native" \
  -v "$XDG_RUNTIME_DIR/pulse:$XDG_RUNTIME_DIR/pulse" \
  -v "$HOME/.config/pulse/cookie:/root/.config/pulse/cookie:ro" \
  --entrypoint ./start.sh jt-live-whisper:cuda --mode en2zh -m small
```

或開 WebUI 的「即時模式」（完整權限時）。**前提**：宿主機正在用 PipeWire/PulseAudio 播放
聲音（喇叭或耳機），且該音訊伺服器可被容器透過上述 socket 連到。

## GPU 加速（CUDA）

需要宿主機已安裝 NVIDIA 驅動與 [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)。
預設映像為 CPU 版；改用 CUDA 版建置即可讓 faster-whisper 使用 GPU：

```bash
docker build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124 \
  -t jt-live-whisper:cuda .
docker run -d --name jt-live-whisper --gpus all \
  -p 127.0.0.1:19781:19781 -v jtlw-data:/data jt-live-whisper:cuda
```

CUDA 版本對應：`cu124`（預設範例，torch 2.6）適用於驅動 >= 525，本機較新的驅動皆可；
需要其他 CUDA 版本時改 `TORCH_INDEX_URL` 即可（`cu121` / `cu126` 等）。

> 為什麼不用 `nvidia/cuda` 基底映像？本映像靠 pip 安裝的 `nvidia-*` 套件提供
> cuBLAS / cuDNN，執行時由 nvidia-container-toolkit 掛入驅動的 `libcuda`；
> 專案的 `start.sh` 會自動把這些函式庫路徑加進 `LD_LIBRARY_PATH`。

## 命令列使用

```bash
# 把音訊檔放進容器可讀的位置，再以 --input 批次處理
docker cp 會議.mp3 jt-live-whisper:/tmp/會議.mp3
docker exec jt-live-whisper ./start.sh --input /tmp/會議.mp3 --mode zh
```

更完整的命令列參數見 `SOP.md` 與 `README.md`。

## 健康檢查

```bash
docker exec jt-live-whisper ./install.sh --doctor
```

容器內會回報「沒有 parec / pw-record」（即時模式不可用）屬正常。

## 升級

```bash
git pull
docker compose up -d --build
```

## 備註

- 底層使用 Ubuntu 24.04 + Python 3.12，避免部分套件尚無新版 Python 的預編譯 wheel。
- 記憶體：離線辨識大模型（large-v3-turbo 等）建議至少 4 GB；CPU 辨識較慢，短檔可用 `small`/`base` 模型。
