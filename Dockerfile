# syntax=docker/dockerfile:1
#
# jt-live-whisper ── Docker 映像（伺服器版）
#
# 以 Ubuntu 24.04 + Python 3.12 建立可重現的環境，安裝流程沿用專案自己的
# install.sh --server，之後升級只要重建映像即可。
#
# 容器內沒有桌面、沒有 systemd，因此：
#   ✅ 可用：離線音檔批次處理、WebUI、講者辨識、會議摘要、字幕轉發
#   ✅ 可用（Linux）：即時系統音訊擷取 ── 將主機的 PipeWire/PulseAudio socket 掛進容器即可
#   ❌ 不可用：懸浮字幕視窗（需要圖形桌面）
#
# 建置（CPU 版，預設）：
#   docker build -t jt-live-whisper .
# 建置（CUDA 版，需要 NVIDIA 驅動 + nvidia-container-toolkit 才能在執行時用 GPU）：
#   docker build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124 \
#                -t jt-live-whisper:cuda .
# 執行（單機用 --network host，本機瀏覽器才有完整權限）：
#   docker run -d --name jt-live-whisper --network host -v jtlw-data:/data jt-live-whisper
#   GPU：再加 --gpus all
# 或：  docker compose up -d
#
# Author: jt-live-whisper contributors

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1

# 系統套件：對應 install-linux.sh 伺服器模式的需求，不含桌面專用套件
# （libxcb-cursor0、fonts-noto-cjk、xdg-utils、PyQt6 等只有桌面版才需要）
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-dev \
        ffmpeg \
        curl \
        unzip \
        openssh-client \
        ca-certificates \
        libportaudio2 \
        pulseaudio-utils \
        build-essential \
        tini

WORKDIR /opt/jt-live-whisper

# 複製程式碼。模型不在此，於下方安裝步驟下載並烘進映像，容器即可離線執行。
COPY . .

# PyTorch 變體：install.sh 依「建置時偵測不偵測得到 nvidia-smi」決定裝 CPU 還是 CUDA 版
# torch，但 docker build 拿不到 GPU，一律會裝 CPU 版。這裡先把想要的 torch 裝進 venv，
# install.sh 看到 torch 已存在就會略過，於是可以自由選擇 CPU 或 CUDA 版。
#   CPU（預設）：https://download.pytorch.org/whl/cpu
#   CUDA      ：https://download.pytorch.org/whl/cu124（依驅動可換 cu121 / cu126）
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m venv /opt/jt-live-whisper/venv \
 && /opt/jt-live-whisper/venv/bin/pip install --disable-pip-version-check --upgrade pip "setuptools<81" wheel \
 && /opt/jt-live-whisper/venv/bin/pip install --disable-pip-version-check torch --index-url "${TORCH_INDEX_URL}"

# 安裝（伺服器模式）。容器內沒有 TTY，統一由 /dev/null 提供 EOF，
# 讓「是否設定 GPU 伺服器」等互動提問自動採用預設值（略過）。
# 容器內沒有 systemd，install-linux.sh 會自動略過服務註冊。
RUN --mount=type=cache,target=/root/.cache/pip \
    bash install.sh --server < /dev/null

EXPOSE 19781
VOLUME ["/data"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/jt-live-whisper/docker/entrypoint.sh"]
CMD ["--webui"]
