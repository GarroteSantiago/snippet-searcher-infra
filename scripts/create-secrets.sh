#!/usr/bin/env bash
# Crea los secretos del stack en el Swarm de una VM, por SSH. Toma cada valor de la variable de
# entorno del mismo nombre en mayúsculas (POSTGRES_PASSWORD, ...); las contraseñas de Postgres
# que falten se generan al azar. Un secreto que ya existe no se toca: los secretos de Swarm no se
# pueden modificar (para cambiar uno: docker stack rm, docker secret rm y de nuevo este script;
# las contraseñas de Postgres además solo se aplican con el volumen vacío).
#
#   AUTH0_M2M_CLIENT_SECRET=... NEW_RELIC_LICENSE_KEY=... scripts/create-secrets.sh azureuser@<vm>
set -euo pipefail

host=${1:?uso: scripts/create-secrets.sh usuario@host}

random() { head -c 24 /dev/urandom | base64 | tr -d '/+='; }

: "${POSTGRES_PASSWORD:=$(random)}"
: "${SNIPPET_DB_PASSWORD:=$(random)}"
: "${PERMISSION_DB_PASSWORD:=$(random)}"
: "${AUTH0_M2M_CLIENT_SECRET:?falta AUTH0_M2M_CLIENT_SECRET}"
# Sin cuenta de New Relic: cualquier valor y NEW_RELIC_ENABLED=false en el deploy
: "${NEW_RELIC_LICENSE_KEY:?falta NEW_RELIC_LICENSE_KEY}"

existing=$(ssh "$host" docker secret ls --format '{{.Name}}')

for name in postgres_password snippet_db_password permission_db_password auth0_m2m_client_secret new_relic_license_key; do
    if grep -qx "$name" <<<"$existing"; then
        echo "= $name ya existe"
        continue
    fi
    var=${name^^}
    printf '%s' "${!var}" | ssh "$host" docker secret create "$name" - >/dev/null
    echo "+ $name"
done
