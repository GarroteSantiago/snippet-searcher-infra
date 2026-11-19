#!/usr/bin/env bash
# Tests de la API (colección de Bruno en api-tests/) contra el sistema levantado con el login
# local (docker-compose.local-auth.yml). Corre la colección entera: cada carpeta usa los tokens
# y el snippet de las anteriores.
#
#   dev/api-tests.sh                                  # salida en la terminal
#   dev/api-tests.sh --reporter-junit results.xml    # además, un reporte JUnit
#   dev/api-tests.sh --bail                          # corta en la primera falla
#
# Lee HTTP_PORT del entorno o de .env.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -z "${HTTP_PORT:-}" ] && [ -f .env ]; then
  HTTP_PORT="$(sed -n 's/^HTTP_PORT=//p' .env)"
fi
port="${HTTP_PORT:?falta HTTP_PORT}"

cd api-tests
exec bru run --env local \
  --env-var "baseUrl=http://localhost:$port/api" \
  --env-var "authUrl=http://auth.localhost:$port/snippet-searcher" \
  "$@"
