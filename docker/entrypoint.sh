#!/usr/bin/env bash
# jt-live-whisper 容器進入點
#
# 1. 把可寫的設定／輸出目錄接到持久化的 /data volume（config.json、recordings/、logs/）
# 2. 可選：用環境變數在初次啟動時設定 WebUI 密碼（只存 sha256，與專案格式一致）
# 3. 交給 start.sh 啟動
set -euo pipefail

APP_DIR=/opt/jt-live-whisper
DATA_DIR="${JTLW_DATA_DIR:-/data}"

mkdir -p "$DATA_DIR/recordings" "$DATA_DIR/logs"

# config.json / recordings / logs 連到持久化目錄（符號連結，路徑仍符合程式預期）
ln -sfn "$DATA_DIR/config.json" "$APP_DIR/config.json"
rm -rf "$APP_DIR/recordings" "$APP_DIR/logs"
ln -sfn "$DATA_DIR/recordings" "$APP_DIR/recordings"
ln -sfn "$DATA_DIR/logs" "$APP_DIR/logs"

# 可選：JTLW_WEBUI_ADMIN_PASSWORD / JTLW_WEBUI_READ_PASSWORD
if [ -n "${JTLW_WEBUI_ADMIN_PASSWORD:-}${JTLW_WEBUI_READ_PASSWORD:-}" ]; then
    JTLW_CONFIG="$APP_DIR/config.json" python3 - <<'PY'
import hashlib, json, os, pathlib

p = pathlib.Path(os.environ["JTLW_CONFIG"])
try:
    cfg = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
except Exception:
    cfg = {}
wp = cfg.get("webui_passwords") or {}
changed = False
for role, env in (("admin", "JTLW_WEBUI_ADMIN_PASSWORD"),
                  ("read", "JTLW_WEBUI_READ_PASSWORD")):
    pw = os.environ.get(env)
    if pw and not wp.get(f"{role}_sha256"):
        wp[f"{role}_sha256"] = hashlib.sha256(pw.encode("utf-8")).hexdigest()
        changed = True
        print(f"[entrypoint] 已設定 WebUI {role} 密碼")
if changed:
    cfg["webui_passwords"] = wp
    p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
PY
fi

cd "$APP_DIR"
exec ./start.sh "$@"
