#!/bin/sh
# Una base y un usuario por servicio. Postgres lo corre solo la primera vez (volumen vacío).
# Las contraseñas llegan por variable (compose) o como archivo, VAR_FILE (docker secret en Swarm).
set -eu

snippet_password=${SNIPPET_DB_PASSWORD:-$(cat "${SNIPPET_DB_PASSWORD_FILE:?falta SNIPPET_DB_PASSWORD}")}
permission_password=${PERMISSION_DB_PASSWORD:-$(cat "${PERMISSION_DB_PASSWORD_FILE:?falta PERMISSION_DB_PASSWORD}")}

psql -v ON_ERROR_STOP=1 --username postgres \
  -v snippet_password="$snippet_password" \
  -v permission_password="$permission_password" <<'SQL'
CREATE USER snippet WITH PASSWORD :'snippet_password';
CREATE DATABASE snippet OWNER snippet;

CREATE USER permission WITH PASSWORD :'permission_password';
CREATE DATABASE permission OWNER permission;
SQL
