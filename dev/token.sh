#!/usr/bin/env bash
# Token de usuario del login local, sin navegador (docker-compose.local-auth.yml).
#
#   dev/token.sh alice            # imprime el access token de auth0|alice
#   TOKEN=$(dev/token.sh bob)
#   curl -H "Authorization: Bearer $TOKEN" localhost:$HTTP_PORT/api/snippets
#
# Usa el grant `password` del servidor de prueba (no pide contraseña real). Lee HTTP_PORT del
# entorno o de .env.
set -euo pipefail

user="${1:-alice}"
cd "$(dirname "$0")/.."
if [ -z "${HTTP_PORT:-}" ] && [ -f .env ]; then
  HTTP_PORT="$(sed -n 's/^HTTP_PORT=//p' .env)"
fi
port="${HTTP_PORT:?falta HTTP_PORT}"

# curl resuelve *.localhost a 127.0.0.1 sin tocar /etc/hosts
curl -sf "http://auth.localhost:$port/snippet-searcher/token" \
  -d grant_type=password \
  -d "username=$user" \
  -d password=local \
  -d client_id=shell \
  -d audience=https://snippet-searcher/api |
  jq -r .access_token
