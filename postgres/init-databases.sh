#!/bin/sh
# Una base y un usuario por servicio. Postgres lo corre solo la primera vez (volumen vacío).
set -eu

psql -v ON_ERROR_STOP=1 --username postgres \
  -v snippet_password="$SNIPPET_DB_PASSWORD" \
  -v permission_password="$PERMISSION_DB_PASSWORD" <<'SQL'
CREATE USER snippet WITH PASSWORD :'snippet_password';
CREATE DATABASE snippet OWNER snippet;

CREATE USER permission WITH PASSWORD :'permission_password';
CREATE DATABASE permission OWNER permission;
SQL
