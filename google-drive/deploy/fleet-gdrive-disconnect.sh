#!/usr/bin/env bash
# Desconecta o Google Drive do usuario atual (logout local do Drive).
# NAO desloga do Linux e NAO apaga a pasta ~/GoogleDrive (arquivos locais ficam).
# No proximo login, o wizard pede a conexao de novo.
set -uo pipefail

REMOTE_NAME="${GDRIVE_REMOTE_NAME:-gdrive}"
MARKER="$HOME/.config/pc-fleet/gdrive.json"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
SERVICE="pc-fleet-gdrive-bisync.service"

log() { logger -t fleet-gdrive-disconnect "$*" 2>/dev/null || true; echo "[gdrive-disconnect] $*"; }

if [[ "$(id -u)" -eq 0 ]]; then
    log "recusado: nao rodar como root"
    exit 0
fi

GUI=""
if command -v zenity >/dev/null 2>&1; then
    GUI="zenity"
elif command -v yad >/dev/null 2>&1; then
    GUI="yad"
fi

confirm() {
    [[ -z "$GUI" ]] && return 0
    if [[ "$GUI" == "zenity" ]]; then
        zenity --question --title="Desconectar Google Drive" \
            --text="Deseja desconectar sua conta do Google Drive deste computador?\n\nSeus arquivos locais em ~/GoogleDrive nao serao apagados." \
            --width=420 2>/dev/null
    else
        yad --question --title="Desconectar Google Drive" \
            --text="Deseja desconectar sua conta do Google Drive deste computador?" \
            --width=420 2>/dev/null
    fi
}

notify() {
    [[ -z "$GUI" ]] && { echo "$1"; return; }
    if [[ "$GUI" == "zenity" ]]; then
        zenity --info --title="Google Drive" --text="$1" --width=420 2>/dev/null || true
    else
        yad --info --title="Google Drive" --text="$1" --width=420 2>/dev/null || true
    fi
}

if ! confirm; then
    log "operador cancelou a desconexao"
    exit 0
fi

# 1/2. Parar e desabilitar o servico de sync.
systemctl --user stop "$SERVICE" 2>/dev/null || true
systemctl --user disable "$SERVICE" 2>/dev/null || true

# 3. Remover a secao [gdrive] do rclone.conf (backup antes).
if [[ -f "$RCLONE_CONF" ]]; then
    cp "$RCLONE_CONF" "${RCLONE_CONF}.bak.$(date +%s)" 2>/dev/null || true
    rclone config delete "$REMOTE_NAME" 2>/dev/null || \
        python3 - "$RCLONE_CONF" "$REMOTE_NAME" <<'PY'
import sys
path, remote = sys.argv[1], sys.argv[2]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except OSError:
    sys.exit(0)
out, skip = [], False
header = f"[{remote}]"
for line in lines:
    stripped = line.strip()
    if stripped == header:
        skip = True
        continue
    if skip and stripped.startswith("[") and stripped.endswith("]"):
        skip = False
    if not skip:
        out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
fi

# 4. Atualizar marcador: configured=false, disconnected_at=agora.
mkdir -p "$(dirname "$MARKER")"
python3 - "$MARKER" <<'PY'
import json, sys, datetime
path = sys.argv[1]
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
try:
    data = json.load(open(path, encoding="utf-8"))
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
data["configured"] = False
data["disconnected_at"] = now
data.setdefault("email", "")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
PY
chmod 600 "$MARKER" 2>/dev/null || true

log "Drive desconectado para $USER"
notify "Google Drive desconectado.\n\nNo proximo login o assistente vai pedir a conexao novamente.\nSeus arquivos locais em ~/GoogleDrive foram mantidos."
exit 0
