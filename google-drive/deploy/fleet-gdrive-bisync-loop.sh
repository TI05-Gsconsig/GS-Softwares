#!/usr/bin/env bash
# Loop de sincronizacao bidirecional do Google Drive (rclone bisync) por usuario.
# Rodado pela unidade systemd --user pc-fleet-gdrive-bisync.service.
set -uo pipefail

LOCAL="${GDRIVE_LOCAL:-$HOME/GoogleDrive}"
REMOTE="${GDRIVE_REMOTE:-gdrive:}"
INTERVAL="${GDRIVE_INTERVAL:-60}"
STATE_DIR="${GDRIVE_STATE_DIR:-$HOME/.cache/rclone/bisync}"
LOG_FILE="${GDRIVE_LOG:-$HOME/.cache/rclone/bisync-loop.log}"

mkdir -p "$LOCAL" "$(dirname "$LOG_FILE")"

gdrive_bisync_extra_flags() {
    local flags=(--max-delete 50)
    if rclone bisync --help 2>&1 | grep -q 'conflict-resolve'; then
        flags+=(--conflict-resolve newer)
    fi
    if rclone bisync --help 2>&1 | grep -q '\-\-resilient'; then
        flags+=(--resilient)
    fi
    printf '%s\n' "${flags[@]}"
}

first_flag=""
if ! ls "$STATE_DIR"/*.lst >/dev/null 2>&1; then
    first_flag="--resync"
fi

mapfile -t _bisync_flags < <(gdrive_bisync_extra_flags)

while true; do
    {
        echo "=== $(date -Iseconds) bisync start (first=${first_flag:-no}) ==="
        # shellcheck disable=SC2086
        rclone bisync "$LOCAL" "$REMOTE" $first_flag \
            "${_bisync_flags[@]}" \
            --log-level INFO
        echo "=== $(date -Iseconds) bisync end rc=$? ==="
    } >>"$LOG_FILE" 2>&1 || true
    first_flag=""
    sleep "$INTERVAL"
done
