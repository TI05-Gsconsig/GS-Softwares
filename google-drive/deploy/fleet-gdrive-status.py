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
