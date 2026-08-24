#!/usr/bin/env bash
# Assistente grafico para conectar o Google Drive do usuario (rclone bisync).
# Roda na SESSAO GRAFICA do proprio operador (via autostart XDG), nunca no PAM
# e nunca como root. Sai calado se o Drive ja estiver configurado.
#
# Deploy (pelo pacote GS-Softwares / install root):
#   /usr/local/bin/fleet-gdrive-wizard
#   /usr/local/lib/pc-fleet/gdrive/  (templates: unit, loop, .desktop)
#   /etc/xdg/autostart/pc-fleet-gdrive-wizard.desktop
set -uo pipefail

REMOTE_NAME="${GDRIVE_REMOTE_NAME:-gdrive}"
LOCAL_DIR="$HOME/GoogleDrive"
MARKER="$HOME/.config/pc-fleet/gdrive.json"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
SERVICE="pc-fleet-gdrive-bisync.service"
LIB_DIR="${FLEET_GDRIVE_LIB:-/usr/local/lib/pc-fleet/gdrive}"
USER_UNIT_DIR="$HOME/.config/systemd/user"

log() { logger -t fleet-gdrive-wizard "$*" 2>/dev/null || true; echo "[gdrive-wizard] $*"; }

# --- Guardas de ambiente -----------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
    log "recusado: nao rodar como root"
    exit 0
fi
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    log "sem sessao grafica (DISPLAY vazio) — abortando"
    exit 0
fi

# --- Ja configurado? ----------------------------------------------------------
marker_configured() {
    [[ -f "$MARKER" ]] || return 1
    python3 - "$MARKER" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("configured") is True else 1)
PY
}

rclone_has_remote() {
    [[ -f "$RCLONE_CONF" ]] && grep -q "^\[${REMOTE_NAME}\]" "$RCLONE_CONF"
}

if marker_configured && rclone_has_remote; then
    log "Drive ja configurado; iniciando servico e saindo"
    systemctl --user start "$SERVICE" 2>/dev/null || true
    exit 0
fi

# --- Ferramenta de dialogo ----------------------------------------------------
GUI=""
if command -v zenity >/dev/null 2>&1; then
    GUI="zenity"
elif command -v yad >/dev/null 2>&1; then
    GUI="yad"
else
    log "zenity/yad ausentes — nao ha como abrir a janela"
    exit 0
fi

ask_email() {
    if [[ "$GUI" == "zenity" ]]; then
        zenity --entry \
            --title="Conectar seu Google Drive" \
            --text="Informe o e-mail da conta Google que sera sincronizada neste computador:" \
            --width=420 2>/dev/null
    else
        yad --entry \
            --title="Conectar seu Google Drive" \
            --text="Informe o e-mail da conta Google:" \
            --width=420 2>/dev/null
    fi
}

info_msg() {
    if [[ "$GUI" == "zenity" ]]; then
        zenity --info --title="Google Drive" --text="$1" --width=420 2>/dev/null || true
    else
        yad --info --title="Google Drive" --text="$1" --width=420 2>/dev/null || true
    fi
}

error_msg() {
    if [[ "$GUI" == "zenity" ]]; then
        zenity --error --title="Google Drive" --text="$1" --width=420 2>/dev/null || true
    else
        yad --error --title="Google Drive" --text="$1" --width=420 2>/dev/null || true
    fi
}

# --- Fluxo --------------------------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
    error_msg "O componente de sincronizacao (rclone) ainda nao esta instalado neste PC. Avise o TI."
    exit 0
fi

email="$(ask_email)"
if [[ -z "$email" ]]; then
    log "operador cancelou; reaparecera no proximo login"
    exit 0
fi
if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    error_msg "E-mail invalido. Tente novamente no proximo login."
    exit 0
fi

# Marcador inicial (auditoria; configured=false ate concluir)
write_marker() {
    local configured="$1" disconnected="$2"
    mkdir -p "$(dirname "$MARKER")"
    python3 - "$MARKER" "$email" "$configured" "$disconnected" <<'PY'
import json, sys, datetime
path, email, configured, disconnected = sys.argv[1:5]
now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
data = {
    "configured": configured == "true",
    "email": email,
    "configured_at": now if configured == "true" else None,
    "disconnected_at": None if disconnected == "false" else now,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
PY
    chmod 600 "$MARKER" 2>/dev/null || true
}

write_marker "false" "false"

info_msg "Uma janela do navegador vai abrir para voce autorizar o acesso ao Google Drive.\n\nEntre com o e-mail:\n$email\n\nDepois de autorizar, pode fechar a aba do navegador."

# OAuth: rclone abre o navegador automaticamente em sessao grafica.
if ! rclone config create "$REMOTE_NAME" drive scope drive config_is_local true >/tmp/fleet-gdrive-oauth.log 2>&1; then
    error_msg "Nao foi possivel concluir a autorizacao do Google Drive. Tente novamente no proximo login."
    log "falha no rclone config create; veja /tmp/fleet-gdrive-oauth.log"
    exit 1
fi

if ! rclone_has_remote; then
    error_msg "A autorizacao nao foi concluida. Tente novamente no proximo login."
    exit 1
fi

mkdir -p "$LOCAL_DIR"

# Sincronizacao inicial (estabelece a linha de base do bisync).
(
    rclone bisync "$LOCAL_DIR" "${REMOTE_NAME}:" --resync \
        --conflict-resolve newer --resilient --max-delete 50 \
        --log-level INFO
) >/tmp/fleet-gdrive-resync.log 2>&1 &
resync_pid=$!

if [[ "$GUI" == "zenity" ]]; then
    (
        while kill -0 "$resync_pid" 2>/dev/null; do echo 50; sleep 1; done
        echo 100
    ) | zenity --progress --pulsate --auto-close --no-cancel \
        --title="Google Drive" --text="Preparando sua pasta GoogleDrive..." --width=420 2>/dev/null || true
fi
wait "$resync_pid" 2>/dev/null || true

# Garante a unidade systemd --user disponivel (system-wide ou na home).
if [[ ! -f "/etc/systemd/user/$SERVICE" && ! -f "$USER_UNIT_DIR/$SERVICE" ]]; then
    if [[ -f "$LIB_DIR/$SERVICE" ]]; then
        mkdir -p "$USER_UNIT_DIR"
        cp "$LIB_DIR/$SERVICE" "$USER_UNIT_DIR/$SERVICE"
    fi
fi

systemctl --user daemon-reload 2>/dev/null || true
if ! systemctl --user enable --now "$SERVICE" 2>/tmp/fleet-gdrive-svc.log; then
    log "aviso: nao foi possivel habilitar $SERVICE; sync pode nao reiniciar sozinho"
fi

# Marca como configurado.
write_marker "true" "false"

# Atalho na area de trabalho (best-effort).
if [[ -f "$LIB_DIR/google-drive.desktop" ]]; then
    desk="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    [[ -z "$desk" || ! -d "$desk" ]] && desk="$HOME/Desktop"
    for d in "$desk" "$HOME/Área de trabalho" "$HOME/Area de Trabalho"; do
        [[ -d "$d" ]] || continue
        cp "$LIB_DIR/google-drive.desktop" "$d/google-drive.desktop" 2>/dev/null || true
        chmod +x "$d/google-drive.desktop" 2>/dev/null || true
        command -v gio >/dev/null 2>&1 && gio set "$d/google-drive.desktop" metadata::trusted true 2>/dev/null || true
    done
fi

info_msg "Google Drive conectado!\n\nSeus arquivos ficam na pasta:\n$LOCAL_DIR\n\nAlteracoes sao sincronizadas automaticamente."
log "Drive configurado para $USER ($email)"
exit 0
