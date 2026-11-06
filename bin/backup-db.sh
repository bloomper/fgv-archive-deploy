#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077

keep_days=${BACKUP_KEEP_DAYS:-14}
target=backups/$(date +%Y-%m-%dT%H%M%S)
mkdir -p "$target"

docker compose exec -T archive-mysql sh -c \
  "MYSQL_PWD=\$(cat /run/secrets/MYSQL_ROOT_PASSWORD) exec mysqldump -uroot --single-transaction --routines --triggers --events --default-character-set=utf8mb4 \"\$MYSQL_DATABASE\"" \
  | gzip > "$target/archive-mysql.sql.gz"
echo "wrote $target/archive-mysql.sql.gz"

find backups -mindepth 1 -maxdepth 1 -type d -mtime "+$keep_days" -exec rm -rf {} +
