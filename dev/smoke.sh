#!/usr/bin/env bash
# Smoke test del sistema completo, contra lo levantado con el login local
# (docker-compose.local-auth.yml): la API (Bruno), la ejecución por WebSocket y la tolerancia a
# fallos de Redis Streams, en ese orden.
#
#   dev/smoke.sh                 # todo, unos dos minutos y medio
#   dev/smoke.sh --sin-fallos    # sin dev/fault-test.sh (mata al Runner), unos 20 segundos
#
# Corre todas las partes aunque falle una, y sale con 1 si falló alguna.
set -uo pipefail

cd "$(dirname "$0")/.."
if [ -z "${HTTP_PORT:-}" ] && [ -f .env ]; then
  HTTP_PORT="$(sed -n 's/^HTTP_PORT=//p' .env)"
fi
export HTTP_PORT="${HTTP_PORT:?falta HTTP_PORT}"

parts=(api-tests ws-test fault-test)
[ "${1:-}" = "--sin-fallos" ] && parts=(api-tests ws-test)

if ! curl -sf -o /dev/null "http://localhost:$HTTP_PORT/api/health"; then
  echo "El sistema no responde en localhost:$HTTP_PORT (ver \"Levantar el sistema\" en el README)"
  exit 1
fi

declare -A result
for part in "${parts[@]}"; do
  echo "=== $part"
  if "dev/$part.sh"; then result[$part]=ok; else result[$part]=FALLÓ; fi
  echo
done

echo "=== Resumen"
status=0
for part in "${parts[@]}"; do
  echo "${result[$part]}  $part"
  [ "${result[$part]}" = ok ] || status=1
done
exit "$status"
