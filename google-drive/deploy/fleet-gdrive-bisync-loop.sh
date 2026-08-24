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
