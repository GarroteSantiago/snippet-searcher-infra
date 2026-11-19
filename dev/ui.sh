#!/usr/bin/env bash
# Construye la UI (../printscript-ui) para el login local y la deja en nginx/html, que NGINX sirve
# en `/` (docker-compose.local-auth.yml).
#
#   dev/ui.sh
#
# El build corre en el dev shell de printscript-ui (Node), así que este dev shell no necesita
# Node. Reemplaza la página provisoria de nginx/html (para volver a ella:
# `git checkout nginx/html && git clean -fd nginx/html`). Lee HTTP_PORT del entorno o de .env.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -z "${HTTP_PORT:-}" ] && [ -f .env ]; then
  HTTP_PORT="$(sed -n 's/^HTTP_PORT=//p' .env)"
fi
port="${HTTP_PORT:?falta HTTP_PORT}"
infra="$PWD"

# nix develop desde adentro del repo de la UI (ver dev/podman-env.sh)
cd ../printscript-ui
[ -d node_modules ] || nix develop -c npm ci
VITE_OIDC_AUTHORITY="http://auth.localhost:$port/snippet-searcher" \
  VITE_OIDC_CLIENT_ID=printscript-ui \
  VITE_OIDC_AUDIENCE=https://snippet-searcher/api \
  nix develop -c npm run build

rm -rf "$infra"/nginx/html/*
cp -r dist/* "$infra/nginx/html/"
echo "UI en http://localhost:$port/"
