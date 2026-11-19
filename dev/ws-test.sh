#!/usr/bin/env bash
# Test de la ejecución interactiva por WebSocket (US-10, contracts/websocket.md) por NGINX, contra
# el sistema levantado con el login local (docker-compose.local-auth.yml).
#
#   dev/ws-test.sh
#
# Bruno no corre WebSockets desde la CLI y el curl de nixpkgs viene sin ws://, así que el cliente
# está acá, en bash puro: /dev/tcp para la conexión y el protocolo a mano (RFC 6455), que para
# mensajes de texto chicos es el handshake y un encabezado de 2 a 8 bytes por mensaje.
#
# Cada corrida entra con usuarios nuevos (ws-owner-<runId>, etc.), como api-tests/. Lee HTTP_PORT
# del entorno o de .env. Sale con 1 si falla algún caso.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -z "${HTTP_PORT:-}" ] && [ -f .env ]; then
  HTTP_PORT="$(sed -n 's/^HTTP_PORT=//p' .env)"
fi
port="${HTTP_PORT:?falta HTTP_PORT}"
api="http://localhost:$port/api"
# Espera máxima por cada mensaje del servidor (el start sin token tarda 5 s en cerrarse)
wait_s=10

# --- Cliente WebSocket ------------------------------------------------------------------------

# Abre el socket en el fd 3 y hace el handshake
ws_open() {
  exec 3<>"/dev/tcp/localhost/$port"
  printf 'GET /api/ws/snippets/%s/run HTTP/1.1\r\nHost: localhost:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' "$1" "$port" >&3
  local status line
  IFS= read -r -t "$wait_s" status <&3 || status=""
  while IFS= read -r -t "$wait_s" line <&3 && [ "${line%$'\r'}" != "" ]; do :; done
  [[ $status == "HTTP/1.1 101"* ]]
}

ws_close() { exec 3>&- 3<&- || true; }

# Un mensaje de texto. El cliente tiene que enmascarar; con la clave 0 el contenido queda igual
ws_send() {
  local n=${#1}
  if [ "$n" -lt 126 ]; then
    printf '\x81'"\\x$(printf %02x $((n | 128)))"'\0\0\0\0' >&3
  else
    printf '\x81\xfe'"\\x$(printf %02x $((n >> 8)))\\x$(printf %02x $((n & 255)))"'\0\0\0\0' >&3
  fi
  printf '%s' "$1" >&3
}

# n bytes del socket como enteros separados por espacios (falla si no llegan a tiempo)
ws_bytes() {
  local out
  out=$(timeout "$wait_s" head -c "$1" <&3 | od -An -v -tu1) || return 1
  [ "$(wc -w <<<"$out")" -eq "$1" ] || return 1
  echo "$out"
}

# Imprime el próximo mensaje: el JSON de un mensaje de texto o `close <código>`
ws_recv() {
  local h l c
  read -r -a h <<<"$(ws_bytes 2)" || return 1
  local op=$((h[0] & 15)) len=$((h[1] & 127))
  if [ "$len" -eq 126 ]; then
    read -r -a l <<<"$(ws_bytes 2)" || return 1
    len=$((l[0] * 256 + l[1]))
  elif [ "$len" -eq 127 ]; then
    return 1 # más de 64 KiB: estos tests no los mandan
  fi
  if [ "$op" -eq 8 ]; then
    if [ "$len" -ge 2 ]; then
      read -r -a c <<<"$(ws_bytes 2)" || return 1
      [ "$len" -gt 2 ] && timeout "$wait_s" head -c $((len - 2)) <&3 >/dev/null
      echo "close $((c[0] * 256 + c[1]))"
    else
      echo "close 1005"
    fi
  else
    timeout "$wait_s" head -c "$len" <&3
    echo
  fi
}

# --- Casos ------------------------------------------------------------------------------------

failures=0
current=""
step() { current="$1"; }
pass() { echo "✓ $current"; }
fail() { echo "✗ $current: $1"; failures=$((failures + 1)); }

# expect <filtro de jq>: el próximo mensaje tiene que cumplirlo. `close <código>` pide el cierre
expect() {
  local msg
  msg=$(ws_recv) || { fail "no llegó nada (esperaba $1)"; return 1; }
  if [[ $1 == close* ]]; then
    [ "$msg" = "$1" ] && return 0
  elif [[ $msg != close* ]] && jq -e "$1" >/dev/null 2>&1 <<<"$msg"; then
    return 0
  fi
  fail "llegó $msg (esperaba $1)"
  return 1
}

start_msg() { jq -nc --arg t "$1" '{type: "start", token: $t}'; }
input_msg() { jq -nc --arg v "$1" '{type: "input", value: $v}'; }

run_id="$(date +%s)-$RANDOM"
owner="ws-owner-$run_id" reader="ws-reader-$run_id" other="ws-other-$run_id"
owner_token=$(dev/token.sh "$owner")
reader_token=$(dev/token.sh "$reader")
other_token=$(dev/token.sh "$other")

content='println("Inicio");
let nombre: string = readInput("Nombre");
println("Hola " + nombre);'
snippet_id=$(
  jq -n --arg c "$content" '{name: "ws-test", description: "dev/ws-test.sh", language: "printscript", version: "1.1", extension: "ps", content: $c}' |
    curl -sf -H "Authorization: Bearer $owner_token" -H 'Content-Type: application/json' -d @- "$api/snippets" |
    jq -r .id
)
trap 'curl -sf -X DELETE -H "Authorization: Bearer $owner_token" "$api/snippets/$snippet_id" >/dev/null || true' EXIT
curl -sf -H "Authorization: Bearer $owner_token" -H 'Content-Type: application/json' \
  -d "{\"userId\": \"auth0|$reader\"}" "$api/snippets/$snippet_id/share" >/dev/null
echo "Snippet $snippet_id de $owner, compartido con $reader"

step "El dueño corre el snippet: output, input-request, input y done ok"
if ws_open "$snippet_id"; then
  ws_send "$(start_msg "$owner_token")"
  expect '.type == "output" and .value == "Inicio"' &&
    expect '.type == "input-request" and .prompt == "Nombre"' &&
    ws_send "$(input_msg Ana)" &&
    expect '.type == "output" and .value == "Hola Ana"' &&
    expect '.type == "done" and .status == "ok"' &&
    expect 'close 1000' &&
    pass
else fail "el handshake no dio 101"; fi
ws_close

step "Un lector (compartido) también puede correrlo"
if ws_open "$snippet_id"; then
  ws_send "$(start_msg "$reader_token")"
  expect '.type == "output" and .value == "Inicio"' &&
    expect '.type == "input-request"' &&
    ws_send "$(input_msg Beto)" &&
    expect '.value == "Hola Beto"' &&
    expect '.type == "done" and .status == "ok"' &&
    pass
else fail "el handshake no dio 101"; fi
ws_close

step "stop mientras espera un input: done stopped"
if ws_open "$snippet_id"; then
  ws_send "$(start_msg "$owner_token")"
  expect '.type == "output"' &&
    expect '.type == "input-request"' &&
    ws_send '{"type":"stop"}' &&
    expect '.type == "done" and .status == "stopped"' &&
    pass
else fail "el handshake no dio 101"; fi
ws_close

step "Un segundo start en la misma sesión: 4409"
if ws_open "$snippet_id"; then
  ws_send "$(start_msg "$owner_token")"
  expect '.type == "output"' &&
    expect '.type == "input-request"' &&
    ws_send "$(start_msg "$owner_token")" &&
    expect 'close 4409' &&
    pass
else fail "el handshake no dio 101"; fi
ws_close

step "Token inválido: 4401"
if ws_open "$snippet_id"; then
  ws_send "$(start_msg not-a-jwt)"
  expect 'close 4401' && pass
else fail "el handshake no dio 101"; fi
ws_close

step "Primer mensaje que no es start: 4401"
if ws_open "$snippet_id"; then
  ws_send "$(input_msg 42)"
  expect 'close 4401' && pass
else fail "el handshake no dio 101"; fi
ws_close

step "Sin start en 5 s: 4401"
if ws_open "$snippet_id"; then
  expect 'close 4401' && pass
else fail "el handshake no dio 101"; fi
ws_close

step "Usuario sin acceso: 4404"
if ws_open "$snippet_id"; then
  ws_send "$(start_msg "$other_token")"
  expect 'close 4404' && pass
else fail "el handshake no dio 101"; fi
ws_close

step "Snippet inexistente: 4404"
if ws_open "$(cat /proc/sys/kernel/random/uuid)"; then
  ws_send "$(start_msg "$owner_token")"
  expect 'close 4404' && pass
else fail "el handshake no dio 101"; fi
ws_close

if [ "$failures" -gt 0 ]; then
  echo "WebSocket: $failures caso(s) fallaron"
  exit 1
fi
echo "WebSocket: todos los casos pasaron"
