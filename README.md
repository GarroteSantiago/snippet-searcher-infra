# snippet-searcher-infra

Infraestructura de Snippet Searcher: el sistema completo con docker compose, la configuración de NGINX y (más adelante) los stacks de Docker Swarm por ambiente.

## Requisitos

- [Nix](https://nixos.org) con flakes: `nix develop` trae docker-compose, `psql`, `redis-cli`, `curl` y `jq`.
- Docker. En NixOS: `virtualisation.docker.enable = true;` en la configuración del sistema.

## Levantar el sistema

```sh
nix develop
cp .env.example .env    # completar Auth0, contraseñas y REGISTRY

# Con las imágenes publicadas en GHCR
docker-compose up -d

# Construyendo desde los repos clonados al lado de este (../snippet-service, etc.)
docker-compose -f docker-compose.yml -f docker-compose.build.yml up -d --build

curl localhost/api/health
```

| Servicio | Imagen | Notas |
|---|---|---|
| `nginx` | `nginx:1.27-alpine` | Único puerto publicado (`HTTP_PORT`). `/api/*` va al Snippet Service sin el prefijo; `/` sirve la UI |
| `snippet-service` | `${REGISTRY}/snippet-service:${TAG}` | Orquestador |
| `permission-service` | `${REGISTRY}/permission-service:${TAG}` | |
| `printscript-runner` | `${REGISTRY}/printscript-runner:${TAG}` | |
| `asset-service` | `ghcr.io/austral-ingsis/snippet-asset-service` | Imagen de la cátedra, sobre Azurite |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | Contenido de los snippets |
| `postgres` | `postgres:16-alpine` | Una base y un usuario por servicio (`postgres/init-databases.sh`, solo con el volumen vacío) |
| `redis` | `redis:7-alpine` | Streams, con AOF |

Inspeccionar el estado:

```sh
docker-compose exec postgres psql -U postgres -c '\l'
docker-compose exec redis redis-cli XINFO GROUPS snippet:jobs
```

NGINX agrega `X-Correlation-Id` a cada request que no lo trae, así un pedido se puede seguir en los logs de todos los servicios.

## Migrar a GitHub

```sh
gh repo create <owner>/snippet-searcher-infra --private --source . --remote origin
git push -u origin dev prod
gh repo edit <owner>/snippet-searcher-infra --default-branch dev
```

CI (`ci.yml`) valida los archivos de compose en cada pull request.
