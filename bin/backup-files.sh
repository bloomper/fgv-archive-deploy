#!/usr/bin/env bash
# Copies the archive's files, which cannot be recreated, to off-host storage with restic. Previews are made again by
# the FILE_BACKFILL job and unfinished uploads are thrown away after 24 hours, so both are left out.
# RESTIC_REPOSITORY and RESTIC_PASSWORD_FILE must be set, e.g. in the environment of the cron job.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"

restic backup --tag archive ./data/archive/files
restic forget --tag archive --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
