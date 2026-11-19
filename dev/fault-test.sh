#!/usr/bin/env bash
# Tolerancia a fallos de Redis Streams (etapa 6, contracts/redis-streams.md, "Reglas de
# procesamiento") contra el sistema levantado con el login local (docker-compose.local-auth.yml).
#
#   dev/fault-test.sh
#
# 1. Runner muerto a mitad de un reproceso: cambia las reglas de lint de un usuario con muchos
#    snippets y hace `docker-compose kill printscript-runner` mientras el Runner todavía los procesa.
#    Al volver a levantarlo, los reclama con XAUTOCLAIM (después de `min-idle`, 60 s) y todos los
#    snippets llegan a su compliance final.
# 2. Máximo de entregas: un job entregado más de 3 veces se descarta (resultado FAILED, XACK) y su
#    snippet queda `failed`; uno entregado justo 3 veces todavía se procesa. Matar al Runner cuatro
#    veces tarda varios minutos, así que lo simula un consumidor `ghost` que toma el job y le fija
#    el contador con XCLAIM ... RETRYCOUNT, como si se hubiera caído con él en la mano.
#
# Tarda unos dos minutos (min-idle más el intervalo de reclamo). Lee HTTP_PORT del entorno o de
# .env. Sale con 1 si falla algún chequeo.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -z "${HTTP_PORT:-}" ] && [ -f .env ]; then
  HTTP_PORT="$(sed -n 's/^HTTP_PORT=//p' .env)"
fi
port="${HTTP_PORT:?falta HTTP_PORT}"
api="http://localhost:$port/api"
case ":${COMPOSE_FILE:-}:" in
  *:docker-compose.local-auth.yml:*) ;;
  *) export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}:docker-compose.local-auth.yml" ;;
esac

jobs_stream=snippet:jobs
group=printscript-runner
snippets_a=30   # bastantes y largos, para que el Runner tarde unos segundos y se lo mate a mitad
lines=2000

failures=0
ok() { echo "✓ $1"; }
ko() { echo "✗ $1"; failures=$((failures + 1)); }
log() { echo "· $1"; }

redis() { docker-compose exec -T redis redis-cli "$@"; }
runner_up() {
  docker-compose start printscript-runner >/dev/null 2>&1
  for _ in $(seq 1 60); do
    # El Runner crea el grupo y empieza a leer recién cuando arrancó Spring
    docker-compose logs --since "$1" printscript-runner 2>/dev/null | grep -q "Consuming $jobs_stream" && return 0
    sleep 1
  done
  return 1
}
# Jobs entregados y sin ack de todo el grupo, sin contar los de ghost
pending_runner() {
  redis XPENDING "$jobs_stream" "$group" - + 1000 | awk 'NR % 4 == 2 && $0 != "ghost"' | wc -l
}

api_get() { curl -sf -H "Authorization: Bearer $1" "$api$2"; }
compliances() { api_get "$1" "/snippets?page_size=100" | jq -c '[.snippets[].compliance] | group_by(.) | map({(.[0]): length}) | add // {}'; }
pending_count() { api_get "$1" "/snippets?page_size=100" | jq '[.snippets[] | select(.compliance == "pending")] | length'; }

# Espera a que ningún snippet del usuario quede en pending (hasta $2 segundos)
wait_final() {
  local deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(pending_count "$1")" = 0 ] && return 0
    sleep 2
  done
  return 1
}

create_snippets() { # token, cantidad, nombre
  local content
  content=$(for i in $(seq 1 "$lines"); do echo "let valorNumero$i: number = $i;"; done)
  for i in $(seq 1 "$2"); do
    jq -n --arg c "$content" --arg n "$3-$i" '{name: $n, language: "printscript", version: "1.1", extension: "ps", content: $c}' |
      curl -sf -o /dev/null -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d @- "$api/snippets"
  done
}

# PUT /rules/lint con identifier_format en snake case: los snippets (camel case) pasan a not-compliant
snake_case() {
  api_get "$1" /rules/lint |
    jq -c 'map(if .id == "identifier_format" then .value = "snake case" else . end)' |
    curl -sf -o /dev/null -X PUT -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d @- "$api/rules/lint"
}

run_id="$(date +%s)-$RANDOM"
token_a=$(dev/token.sh "ft-a-$run_id")
token_b=$(dev/token.sh "ft-b-$run_id")
cleanup() {
  for t in "$token_a" "$token_b"; do
    for id in $(api_get "$t" "/snippets?page_size=100" | jq -r '.snippets[].id' 2>/dev/null); do
      curl -sf -o /dev/null -X DELETE -H "Authorization: Bearer $t" "$api/snippets/$id" || true
    done
  done
  redis XGROUP DELCONSUMER "$jobs_stream" "$group" ghost >/dev/null 2>&1 || true
  docker-compose start printscript-runner >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Lo que quedó de una corrida anterior confundiría la cuenta de jobs sin ack
for _ in $(seq 1 60); do
  [ "$(redis XPENDING "$jobs_stream" "$group" | head -1)" = 0 ] && break
  sleep 3
done
[ "$(redis XPENDING "$jobs_stream" "$group" | head -1)" = 0 ] || { ko "$jobs_stream tiene jobs sin ack de antes"; exit 1; }

log "Creando $snippets_a snippets de ft-a-$run_id y 2 de ft-b-$run_id"
create_snippets "$token_a" "$snippets_a" a
create_snippets "$token_b" 2 b
wait_final "$token_a" 60 && wait_final "$token_b" 60 || { ko "el lint inicial no terminó"; exit 1; }
log "Lint inicial: A $(compliances "$token_a"), B $(compliances "$token_b")"

# --- Runner muerto a mitad del reproceso ---------------------------------------------------------

# Las reglas se leen y se guardan con el catálogo del Runner (sin él, 502): los dos PUT van con el
# Runner levantado, y se lo mata apenas vuelven, mientras sigue con los LINT de A. Los de B quedan
# al final del stream, todavía sin ack
snake_case "$token_a"
snake_case "$token_b"
docker-compose kill printscript-runner >/dev/null 2>&1
held=$(pending_runner)
left=$(pending_count "$token_a")
log "Runner muerto con $held jobs sin ack; $left de $snippets_a snippets de A en pending"
[ "$held" -gt 0 ] && [ "$left" -gt 0 ] ||
  { ko "el Runner terminó antes de matarlo: subir snippets_a o lines"; exit 1; }

# --- Máximo de entregas: ghost toma los LINT de B y les fija el contador ---------------------------

# Los dos últimos del stream son los de B (el PUT de B fue el último en publicar)
b_jobs=$(redis --json XREVRANGE "$jobs_stream" + - COUNT 2 |
  jq -r '.[] | [.[0], (.[1] as $f | [range(0; $f | length; 2) | {($f[.]): $f[. + 1]}] | add | .payload | fromjson | .snippetId)] | @tsv' | tac)
b_snippets=$(api_get "$token_b" "/snippets?page_size=100" | jq -r '.snippets[].id' | sort)
[ "$(cut -f2 <<<"$b_jobs" | sort)" = "$b_snippets" ] ||
  { ko "los últimos jobs del stream no son los de B"; exit 1; }
read -r retry_2 snippet_2 retry_3 snippet_3 <<<"$(echo $b_jobs)"

# Lo que el Runner no llegó a leer pasa a ghost: también se recupera solo con XAUTOCLAIM
redis XREADGROUP GROUP "$group" ghost COUNT 1000 STREAMS "$jobs_stream" '>' >/dev/null
# IDLE alto: reclamables en la primera pasada. XAUTOCLAIM suma una entrega más: 3 y 4
for claim in "$retry_2 2" "$retry_3 3"; do
  set -- $claim
  [ -n "$(redis XCLAIM "$jobs_stream" "$group" ghost 0 "$1" IDLE 3600000 RETRYCOUNT "$2" JUSTID)" ] ||
    { ko "el job $1 de B ya tenía ack: el Runner llegó a procesarlo"; exit 1; }
done
deliveries() { redis XPENDING "$jobs_stream" "$group" "$1" "$1" 1 | sed -n 4p; }
log "B: job $retry_2 (snippet $snippet_2) con $(deliveries "$retry_2") entregas, $retry_3 (snippet $snippet_3) con $(deliveries "$retry_3")"

recovery=$SECONDS
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
runner_up "$since" || { ko "el Runner no volvió a arrancar"; exit 1; }
log "Runner levantado de nuevo; esperando el reclamo (min-idle 60 s, cada 30 s)"

if wait_final "$token_a" 180; then
  ok "Ningún snippet de A quedó en pending ($((SECONDS - recovery)) s después de levantar el Runner)"
else
  ko "A sigue con $(pending_count "$token_a") snippets en pending"
fi
final_a=$(compliances "$token_a")
[ "$final_a" = "{\"not-compliant\":$snippets_a}" ] &&
  ok "Los $snippets_a snippets de A quedaron not-compliant con las reglas nuevas" ||
  ko "compliance final de A: $final_a"

reclaimed=$(docker-compose logs --no-log-prefix --since "$since" printscript-runner |
  grep -o '"message":"Reclaimed[^"]*"' | cut -d'"' -f4 | head -3 || true)
[ -n "$reclaimed" ] && ok "El Runner reclamó los pendientes con XAUTOCLAIM: $(echo $reclaimed)" ||
  ko "no hay \"Reclaimed\" en los logs del Runner"

wait_final "$token_b" 60 || true
c2=$(api_get "$token_b" "/snippets/$snippet_2" | jq -r .compliance)
c3=$(api_get "$token_b" "/snippets/$snippet_3" | jq -r .compliance)
[ "$c2" = not-compliant ] && ok "Job entregado 3 veces: se procesó (not-compliant)" || ko "job entregado 3 veces: compliance $c2"
[ "$c3" = failed ] && ok "Job entregado 4 veces: se descartó y el snippet quedó failed" || ko "job entregado 4 veces: compliance $c3"

left=$(redis XPENDING "$jobs_stream" "$group" | head -1)
[ "$left" = 0 ] && ok "No quedan jobs sin ack en $jobs_stream" || ko "quedan $left jobs sin ack en $jobs_stream"

if [ "$failures" -gt 0 ]; then
  echo "Tolerancia a fallos: $failures chequeo(s) fallaron"
  exit 1
fi
echo "Tolerancia a fallos: todos los chequeos pasaron"
