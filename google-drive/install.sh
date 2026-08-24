#!/bin/bash
# Instala Google Drive (rclone bisync) para a Frota de PCs — escopo global (root).
set -euo pipefail

if ! declare -F gs_install_apt_packages >/dev/null 2>&1; then
  _gs_tools=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _gs_tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" 2>/dev/null && pwd || true)"
  fi
  if [[ -z "$_gs_tools" || ! -f "$_gs_tools/install_lib.sh" ]]; then
    echo "Biblioteca GS install_lib.sh nao encontrada" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$_gs_tools/install_lib.sh"
fi

LIB_DIR="/usr/local/lib/pc-fleet/gdrive"
BIN_WIZARD="/usr/local/bin/fleet-gdrive-wizard"
BIN_DISCONNECT="/usr/local/bin/fleet-gdrive-disconnect"
AUTOSTART="/etc/xdg/autostart/pc-fleet-gdrive-wizard.desktop"
USER_UNIT="/etc/systemd/user/pc-fleet-gdrive-bisync.service"

write_embedded_files() {
  local tmp
  tmp="$(mktemp -d /tmp/gs-gdrive-deploy.XXXXXX)"
  cat >"$tmp/fleet-gdrive-bisync-loop.sh" <<'GDRIVE_EOF_fleet-gdrive-bisync-loop_sh'
#!/usr/bin/env bash
# Loop de sincronizacao bidirecional do Google Drive (rclone bisync) por usuario.
# Rodado pela unidade systemd --user pc-fleet-gdrive-bisync.service.
#
# rclone bisync e "one-shot": para manter o Drive sincronizado continuamente,
# repetimos a passada a cada GDRIVE_INTERVAL segundos. A primeira passada usa
# --resync somente se ainda nao existe estado anterior (o wizard normalmente ja
# fez o --resync inicial).
set -uo pipefail

LOCAL="${GDRIVE_LOCAL:-$HOME/GoogleDrive}"
REMOTE="${GDRIVE_REMOTE:-gdrive:}"
INTERVAL="${GDRIVE_INTERVAL:-60}"
STATE_DIR="${GDRIVE_STATE_DIR:-$HOME/.cache/rclone/bisync}"

mkdir -p "$LOCAL"

first_flag=""
if ! ls "$STATE_DIR"/*.lst >/dev/null 2>&1; then
    # Sem estado anterior: primeira passada precisa estabelecer a linha de base.
    first_flag="--resync"
fi

while true; do
    # shellcheck disable=SC2086
    rclone bisync "$LOCAL" "$REMOTE" $first_flag \
        --conflict-resolve newer \
        --resilient \
        --max-delete 50 \
        --log-level INFO 2>&1 | tail -n 200 || true
    first_flag=""
    sleep "$INTERVAL"
done
GDRIVE_EOF_fleet-gdrive-bisync-loop_sh
  cat >"$tmp/fleet-gdrive-disconnect.sh" <<'GDRIVE_EOF_fleet-gdrive-disconnect_sh'
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
GDRIVE_EOF_fleet-gdrive-disconnect_sh
  cat >"$tmp/fleet-gdrive-status.py" <<'GDRIVE_EOF_fleet-gdrive-status_py'
#!/usr/bin/env python3
"""Detecta o status do Google Drive (rclone bisync) por usuario Linux no PC.

Autonomo: nao importa nada do backend FastAPI, roda no PC remoto da frota
(chamado por ``collect-software.sh`` ou manualmente por TI). Analisa todos os
operadores em ``/etc/pc-fleet/user-fleet-groups.conf`` mais qualquer home que ja
tenha configuracao do Drive, e resume um status agregado para o painel.

Saida (stdout, JSON):

    {
      "gdrive_installed": true,
      "gdrive_by_user": [
        {"linux_user": "joao", "status": "ok", "email": "joao@empresa.com", "detail": ""}
      ],
      "gdrive_aggregate": "ok"
    }

Status por usuario:
    missing       rclone nao instalado no PC
    needs_oauth   instalado; operador ainda nao conectou (aguardando wizard)
    ok            configurado (marcador + remote rclone presentes)
    disconnected  operador usou fleet-gdrive-disconnect neste PC
    error         marcador diz configurado mas o remote sumiu / inconsistente
    unknown       sem permissao para ler a home do usuario
"""
from __future__ import annotations

import argparse
import json
import os
import pwd
import subprocess
from pathlib import Path
from shutil import which

GROUPS_FILE = Path(os.environ.get("FLEET_GROUPS_FILE", "/etc/pc-fleet/user-fleet-groups.conf"))
MARKER_REL = ".config/pc-fleet/gdrive.json"
RCLONE_CONF_REL = ".config/rclone/rclone.conf"
REMOTE_NAME = os.environ.get("GDRIVE_REMOTE_NAME", "gdrive")

# Contas de sistema/servico que nunca sao operadores da frota.
SYSTEM_USERS = {
    "root",
    "lightdm",
    "gdm",
    "sddm",
    "nobody",
    "daemon",
    "sync",
    "systemd-network",
}


def rclone_installed() -> bool:
    return which("rclone") is not None


def _read_text(path: Path) -> str | None:
    """Le um arquivo; tenta ``sudo -n`` se faltar permissao (PC compartilhado)."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return None
    except PermissionError:
        probe = subprocess.run(
            ["sudo", "-n", "cat", str(path)],
            capture_output=True,
            text=True,
        )
        if probe.returncode == 0:
            return probe.stdout
        return ""  # existe mas sem permissao de leitura
    except OSError:
        return None


def _host_short() -> str:
    try:
        return subprocess.run(
            ["hostname", "-s"], capture_output=True, text=True
        ).stdout.strip() or os.uname().nodename
    except OSError:
        return os.uname().nodename


def operators_from_groups() -> list[str]:
    """Extrai os usuarios do groups.conf que se aplicam a este host."""
    text = _read_text(GROUPS_FILE)
    if not text:
        return []
    host = _host_short()
    users: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 3:
            # host user slug
            if parts[0] in (host, "*"):
                users.append(parts[1])
        elif len(parts) == 2:
            # user slug
            users.append(parts[0])
    return users


def _safe_exists(path: Path) -> bool:
    """os.stat pode lançar PermissionError na home de outro usuario (py>=3.12)."""
    try:
        return path.exists()
    except OSError:
        return False


def homes_with_config() -> list[str]:
    """Usuarios cuja home ja tem marcador do Drive ou remote rclone."""
    found: list[str] = []
    home_root = Path("/home")
    if not home_root.is_dir():
        return found
    try:
        entries = sorted(p for p in home_root.iterdir() if p.is_dir())
    except OSError:
        return found
    for home in entries:
        user = home.name
        if user in SYSTEM_USERS:
            continue
        if _safe_exists(home / MARKER_REL) or _safe_exists(home / RCLONE_CONF_REL):
            found.append(user)
    return found


def resolve_home(user: str) -> Path | None:
    try:
        return Path(pwd.getpwnam(user).pw_dir)
    except KeyError:
        candidate = Path("/home") / user
        return candidate if candidate.is_dir() else None


def rclone_conf_has_remote(home: Path) -> bool:
    text = _read_text(home / RCLONE_CONF_REL)
    if not text:
        return False
    return f"[{REMOTE_NAME}]" in text


def parse_marker(home: Path) -> dict[str, object]:
    text = _read_text(home / MARKER_REL)
    if not text:
        return {}
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def status_for_user(user: str, installed: bool) -> dict[str, str]:
    entry = {"linux_user": user, "status": "needs_oauth", "email": "", "detail": ""}
    if not installed:
        entry["status"] = "missing"
        entry["detail"] = "rclone nao instalado no PC"
        return entry

    home = resolve_home(user)
    if home is None:
        entry["status"] = "unknown"
        entry["detail"] = "home do usuario nao encontrada"
        return entry

    marker = parse_marker(home)
    has_remote = rclone_conf_has_remote(home)
    configured = bool(marker.get("configured"))
    email = str(marker.get("email", "") or "")
    disconnected_at = marker.get("disconnected_at")
    entry["email"] = email

    if configured and has_remote:
        entry["status"] = "ok"
    elif configured and not has_remote:
        entry["status"] = "error"
        entry["detail"] = "marcado como configurado mas remote gdrive ausente"
    elif has_remote and not configured:
        # Remote existe sem marcador (config manual) — considerar conectado.
        entry["status"] = "ok"
        entry["detail"] = "remote rclone presente sem marcador da frota"
    elif disconnected_at and not configured:
        entry["status"] = "disconnected"
        entry["detail"] = "operador desconectou o Drive neste PC"
    else:
        entry["status"] = "needs_oauth"
        entry["detail"] = "aguardando wizard no login"
    return entry


def aggregate(statuses: list[str], installed: bool) -> str:
    if not installed:
        return "missing"
    if not statuses:
        return "needs_oauth"
    unique = set(statuses)
    if "error" in unique:
        return "error"
    if unique == {"ok"}:
        return "ok"
    if unique == {"needs_oauth"}:
        return "needs_oauth"
    if unique == {"disconnected"}:
        return "disconnected"
    if unique == {"missing"}:
        return "missing"
    if unique <= {"unknown"}:
        return "needs_oauth"
    # Mistura de conectados e nao conectados.
    return "partial"


def collect(users: list[str] | None = None) -> dict[str, object]:
    installed = rclone_installed()
    if users is None:
        candidates: list[str] = []
        seen: set[str] = set()
        for user in operators_from_groups() + homes_with_config():
            if user in SYSTEM_USERS or user in seen:
                continue
            seen.add(user)
            candidates.append(user)
        users = candidates

    by_user = [status_for_user(user, installed) for user in users]
    agg = aggregate([entry["status"] for entry in by_user], installed)
    return {
        "gdrive_installed": installed,
        "gdrive_by_user": by_user,
        "gdrive_aggregate": agg,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Status do Google Drive (rclone) por usuario")
    parser.add_argument(
        "--users",
        help="Lista de usuarios Linux separada por virgula (padrao: detecta sozinho)",
        default="",
    )
    args = parser.parse_args()
    users = None
    if args.users.strip():
        users = [u.strip() for u in args.users.split(",") if u.strip()]
    print(json.dumps(collect(users), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
GDRIVE_EOF_fleet-gdrive-status_py
  cat >"$tmp/fleet-gdrive-wizard.sh" <<'GDRIVE_EOF_fleet-gdrive-wizard_sh'
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
GDRIVE_EOF_fleet-gdrive-wizard_sh
  cat >"$tmp/gdrive.json.example" <<'GDRIVE_EOF_gdrive_json_example'
{
  "configured": true,
  "email": "operador@empresa.com",
  "configured_at": "2026-08-21T17:00:00-03:00",
  "disconnected_at": null
}
GDRIVE_EOF_gdrive_json_example
  cat >"$tmp/google-drive-disconnect.desktop" <<'GDRIVE_EOF_google-drive-disconnect_desktop'
[Desktop Entry]
Version=1.0
Type=Application
Name=Desconectar Google Drive
Name[pt_BR]=Desconectar Google Drive
Comment=Encerrar a sincronizacao e remover a conta do Google Drive deste login
Comment[pt_BR]=Encerrar a sincronizacao e remover a conta do Google Drive deste login
Exec=fleet-gdrive-disconnect
Icon=folder-google-drive
Terminal=false
Categories=Network;Utility;
GDRIVE_EOF_google-drive-disconnect_desktop
  cat >"$tmp/google-drive.desktop" <<'GDRIVE_EOF_google-drive_desktop'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Drive
Name[pt_BR]=Google Drive
Comment=Abrir a pasta sincronizada do Google Drive
Comment[pt_BR]=Abrir a pasta sincronizada do Google Drive
Exec=sh -c "xdg-open \\"$HOME/GoogleDrive\\""
Icon=folder-google-drive
Terminal=false
Categories=Network;Utility;
GDRIVE_EOF_google-drive_desktop
  cat >"$tmp/pc-fleet-gdrive-bisync.service" <<'GDRIVE_EOF_pc-fleet-gdrive-bisync_service'
[Unit]
Description=Google Drive sync (Frota) via rclone bisync
Documentation=https://github.com/TI05-Gsconsig/pc-fleet-dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Loop de bisync por usuario; para automaticamente ao deslogar (sem linger).
ExecStart=/usr/local/lib/pc-fleet/gdrive/fleet-gdrive-bisync-loop.sh
Restart=on-failure
RestartSec=30
# Evita rodar como root por engano (unidade e --user, mas reforcamos).
Nice=5

[Install]
WantedBy=default.target
GDRIVE_EOF_pc-fleet-gdrive-bisync_service
  cat >"$tmp/pc-fleet-gdrive-wizard.desktop" <<'GDRIVE_EOF_pc-fleet-gdrive-wizard_desktop'
[Desktop Entry]
Version=1.0
Type=Application
Name=Conectar Google Drive
Name[pt_BR]=Conectar Google Drive
Comment=Assistente para conectar sua conta do Google Drive
Comment[pt_BR]=Assistente para conectar sua conta do Google Drive
Exec=fleet-gdrive-wizard
Icon=folder-google-drive
Terminal=false
# Autostart apos a sessao grafica subir; o proprio wizard sai calado se ja configurado.
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=10
NoDisplay=true
GDRIVE_EOF_pc-fleet-gdrive-wizard_desktop

  install -d "$LIB_DIR"
  install -m 0755 "$tmp/fleet-gdrive-bisync-loop.sh" "$LIB_DIR/"
  install -m 0755 "$tmp/fleet-gdrive-status.py" "$LIB_DIR/"
  install -m 0755 "$tmp/fleet-gdrive-wizard.sh" "$BIN_WIZARD"
  install -m 0755 "$tmp/fleet-gdrive-disconnect.sh" "$BIN_DISCONNECT"
  install -m 0644 "$tmp/pc-fleet-gdrive-bisync.service" "$LIB_DIR/"
  install -m 0644 "$tmp/pc-fleet-gdrive-bisync.service" "$USER_UNIT"
  install -m 0644 "$tmp/google-drive.desktop" "$LIB_DIR/"
  install -m 0644 "$tmp/google-drive-disconnect.desktop" "$LIB_DIR/"
  install -m 0644 "$tmp/gdrive.json.example" "$LIB_DIR/"
  install -d "$(dirname "$AUTOSTART")"
  install -m 0644 "$tmp/pc-fleet-gdrive-wizard.desktop" "$AUTOSTART"
  rm -rf "$tmp"
}

export DEBIAN_FRONTEND=noninteractive
# Evita falha quando algum repo de terceiros (ex.: cursor) esta quebrado no apt update.
if ! gs_run_as_root apt-get install -y --no-install-recommends rclone fuse3 zenity; then
  gs_install_apt_packages rclone fuse3 zenity
fi
write_embedded_files
systemctl daemon-reload 2>/dev/null || true
echo "Google Drive (rclone) instalado para a frota"
