#!/usr/bin/env python3
"""Regenera google-drive/install.sh a partir de google-drive/deploy/."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "google-drive" / "deploy"
OUT = ROOT / "google-drive" / "install.sh"

HEADER = r'''#!/bin/bash
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
'''

FOOTER = r'''
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
if ! gs_run_as_root apt-get install -y --no-install-recommends rclone fuse3 zenity; then
  gs_install_apt_packages rclone fuse3 zenity
fi
write_embedded_files
systemctl daemon-reload 2>/dev/null || true
echo "Google Drive (rclone) instalado para a frota"
'''


def main() -> int:
    parts = [HEADER]
    for path in sorted(DEPLOY.iterdir()):
        if not path.is_file():
            continue
        token = path.name.replace(".", "_")
        parts.append(f'  cat >"$tmp/{path.name}" <<\'GDRIVE_EOF_{token}\'\n')
        parts.append(path.read_text(encoding="utf-8").rstrip("\n") + "\n")
        parts.append(f"GDRIVE_EOF_{token}\n")
    parts.append(FOOTER)
    OUT.write_text("".join(parts), encoding="utf-8")
    OUT.chmod(0o755)
    print(f"Gerado {OUT} ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
