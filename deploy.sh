#!/usr/bin/env bash
# Despliega docker-stack.yml en el Swarm de DOCKER_HOST (en CI, ssh://usuario@vm) y espera a que
# los servicios converjan. Las variables del ambiente (DOMAIN, ENVIRONMENT, TAG, Auth0...) llegan
# por el entorno; los secretos ya están creados en el Swarm (scripts/create-secrets.sh).
#
#   ENVIRONMENT=dev TAG=dev REGISTRY=ghcr.io/<owner> DOMAIN=... ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

STACK=snippet-searcher

# Las configs de Swarm no se pueden modificar: un contenido nuevo es una config con otro nombre
CONFIG_VERSION=$(cat nginx/stack/* postgres/init-databases.sh | sha256sum | cut -c1-12)
export CONFIG_VERSION

# --with-registry-auth: las credenciales de GHCR de este cliente (docker login) llegan a los nodos.
# La imagen se resuelve en el registry: si el tag (dev o prod) apunta a otra imagen, el servicio
# se actualiza.
docker stack deploy --with-registry-auth --prune --detach=false -c docker-stack.yml "$STACK"

# Las configs de versiones anteriores quedan sin uso; las que están en uso no se pueden borrar
docker config ls -q --filter "label=com.docker.stack.namespace=$STACK" | xargs -r docker config rm >/dev/null 2>&1 || true

docker stack services "$STACK"
