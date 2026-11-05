#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets

infra_deploy=${INFRA_DEPLOY:-../fgv-infra-deploy}
spexregister_deploy=${SPEXREGISTER_DEPLOY:-../spexregister-deploy}

generate() {
  local name=$1 value=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  else
    printf '%s' "$value" > "secrets/$name"
    echo "created secrets/$name"
  fi
}

# Client secrets are made by fgv-infra-deploy, which sets them in the realm
copy_client_secret() {
  local name=$1 client=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  elif [[ -s $infra_deploy/secrets/clients/$client ]]; then
    cp "$infra_deploy/secrets/clients/$client" "secrets/$name"
    echo "copied secrets/$name from $infra_deploy"
  else
    echo "missing secrets/$name: run bin/init-secrets.sh in fgv-infra-deploy first, or set INFRA_DEPLOY" >&2
  fi
}

random() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

generate MYSQL_ROOT_PASSWORD "$(random 32)"
generate MYSQL_USER_PASSWORD "$(random 32)"
copy_client_secret KEYCLOAK_CLIENT_SECRET fgv-archive
copy_client_secret KEYCLOAK_SERVICE_CLIENT_SECRET fgv-archive-service
# Only the sample data import manages Keycloak users, so the API gets fgv-admin's secret only when it imports
if grep -qx 'API_IMPORT_SAMPLE_DATA=true' .env 2>/dev/null; then
  copy_client_secret KEYCLOAK_ADMIN_CLIENT_SECRET fgv-admin
  if [[ -s secrets/SAMPLE_USER_PASSWORD ]]; then
    echo "keep secrets/SAMPLE_USER_PASSWORD"
  elif [[ -s $spexregister_deploy/secrets/SAMPLE_USER_PASSWORD ]]; then
    cp "$spexregister_deploy/secrets/SAMPLE_USER_PASSWORD" secrets/SAMPLE_USER_PASSWORD
    echo "copied secrets/SAMPLE_USER_PASSWORD from $spexregister_deploy"
  else
    echo "missing secrets/SAMPLE_USER_PASSWORD: run bin/init-secrets.sh in spexregister-deploy first, or set SPEXREGISTER_DEPLOY" >&2
  fi
else
  touch secrets/KEYCLOAK_ADMIN_CLIENT_SECRET secrets/SAMPLE_USER_PASSWORD
fi
generate WEB_AUTH_SECRET "$(random 48)"
if [[ ! -e secrets/SMTP_PASSWORD ]]; then
  : > secrets/SMTP_PASSWORD
  echo "created secrets/SMTP_PASSWORD (empty, write the SMTP password into it if the relay needs one)"
fi
if [[ ! -s secrets/cloudflared.env ]]; then
  printf 'TUNNEL_TOKEN=\n' > secrets/cloudflared.env
  echo "created secrets/cloudflared.env (staging only: paste the tunnel token into it)"
fi

# The containers run as other users than the one owning secrets/, so the secret files must be readable; the
# directory itself stays closed to others
chmod 700 secrets
find secrets -maxdepth 1 -type f ! -name '*.env' -exec chmod 644 {} +
chmod 600 secrets/*.env
