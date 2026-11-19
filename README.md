# snippet-searcher-infra

Infraestructura de Snippet Searcher: el sistema completo con docker compose, la configuración de NGINX y (más adelante) los stacks de Docker Swarm por ambiente.

## Requisitos

- [Nix](https://nixos.org) con flakes: `nix develop` trae docker-compose, `psql`, `redis-cli`, `curl` y `jq`.
- Contenedores: el dev shell trae Podman rootless y lo deja listo para `docker-compose` y Testcontainers (`DOCKER_HOST`), sin instalar nada en el sistema ni correr como root. Imágenes y contenedores quedan en `.podman/` (ignorado por git); para borrar todo: `podman unshare rm -rf .podman`. Ver `dev/podman-env.sh`.

## Levantar el sistema

```sh
nix develop
cp .env.example .env    # completar Auth0, contraseñas y REGISTRY

# Con las imágenes publicadas en GHCR
docker-compose up -d

# Construyendo desde los repos clonados al lado de este (../snippet-service, etc.)
COMPOSE_FILE=$COMPOSE_FILE:docker-compose.build.yml docker-compose up -d --build

curl localhost/api/health
```

Con el Podman rootless del dev shell: el puerto de NGINX tiene que ser mayor a 1024 (por ejemplo `HTTP_PORT=8088`), y el dev shell suma `docker-compose.podman.yml` (sin health checks; ver el comentario del archivo) a través de `COMPOSE_FILE`.

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

**Observabilidad.** Los servicios loguean en JSON (`LOG_FORMAT=plain` para leerlos a mano) y exponen métricas en Prometheus en el puerto interno 9464, que no se publica ni pasa por NGINX:

```sh
docker-compose exec snippet-service curl -s localhost:9464/prometheus | grep redis_stream
```

New Relic queda apagado hasta tener la license key: `NEW_RELIC_ENABLED=true` y `NEW_RELIC_LICENSE_KEY` en `.env` (ver el README de cada servicio).

Con imágenes construidas a mano (`podman build -t snippet-searcher/<servicio>:local`, `REGISTRY=snippet-searcher` y `TAG=local`), `docker-compose up -d --pull never`: si no, compose las busca en docker.io.

## Login local (sin Auth0)

`docker-compose.local-auth.yml` suma un servidor OIDC de prueba ([mock-oauth2-server](https://github.com/navikt/mock-oauth2-server), servicio `oidc`) que emite tokens con la forma de los de Auth0. Los servicios no cambian: el override solo pisa las variables de Auth0 de `.env`.

```sh
# HTTP_PORT tiene que ser distinto de 80 (por ejemplo 8088)
COMPOSE_FILE=$COMPOSE_FILE:docker-compose.local-auth.yml docker-compose up -d

TOKEN=$(dev/token.sh alice)     # token de usuario sin navegador
curl -H "Authorization: Bearer $TOKEN" localhost:8088/api/snippets
```

| Variable | Valor con el login local |
|---|---|
| `AUTH0_ISSUER_URI` | `http://auth.localhost:${HTTP_PORT}/snippet-searcher` (sin barra final) |
| `AUTH0_AUDIENCE` | `https://snippet-searcher/api` |
| `AUTH0_TOKEN_URI` | `http://auth.localhost:${HTTP_PORT}/snippet-searcher/token` |
| `AUTH0_SERVICE_CLIENT_ID` / `_SECRET` | `snippet-service` / `local-secret` (el servidor no valida credenciales) |

**El emisor.** El `iss` tiene que ser el mismo para el navegador y para los servicios, que lo usan para validar. Por eso el servidor de prueba no se publica aparte: va por NGINX con el nombre `auth.localhost` (`nginx/local-auth.conf.template`).

- El navegador y `curl` resuelven `*.localhost` a `127.0.0.1` sin tocar `/etc/hosts`, y llegan por el puerto publicado.
- Dentro de compose, `auth.localhost` es un alias de red de NGINX y NGINX también escucha en `HTTP_PORT`, así que la misma URL llega al mismo lugar. Por eso `HTTP_PORT` no puede ser 80: NGINX ya escucha ahí.
- NGINX fija el `Host` hacia el servidor, que arma el `iss` con él: el token no depende de quién lo pide.

**Tokens.** Firmados con RS256 (JWKS en `${AUTH0_ISSUER_URI}/jwks`, discovery en `${AUTH0_ISSUER_URI}/.well-known/openid-configuration`). La forma la define `local-auth/config.json`:

- Usuario: `sub` = `auth0|<usuario>`, `name`, `nickname`, `email` = `<usuario>@example.com`, `aud` = `[AUTH0_AUDIENCE, <client_id>]`.
- *Client credentials*: `sub` = `<client_id>@clients`, `gty` = `client-credentials`, `aud` = `AUTH0_AUDIENCE`, como en `contracts/README.md`.

**Usuarios.** No hay contraseñas ni registro: cualquier nombre entra (`[A-Za-z0-9._-]+`). La página de login (`local-auth/login.html`) trae botones para `alice` y `bob`, para probar compartir entre dos usuarios.

**Desde la UI.** Authorization Code con PKCE contra `AUTH0_ISSUER_URI` como *authority* (cualquier cliente OIDC genérico, por ejemplo oidc-client-ts). Acepta cualquier `client_id` y `redirect_uri`; `audience` se puede mandar como parámetro extra, pero no cambia nada. El servidor responde con CORS para cualquier origen.

**Desde la terminal.** `dev/token.sh <usuario>` usa el grant `password` del servidor de prueba e imprime el access token. El de *client credentials*:

```sh
curl -s http://auth.localhost:8088/snippet-searcher/token \
  -d grant_type=client_credentials -d client_id=snippet-service -d client_secret=local-secret \
  -d audience=https://snippet-searcher/api | jq -r .access_token
```

**Limitaciones.**

- Compartir usa la Management API de Auth0 (buscar usuarios y comprobar que existen). Con el login local la reemplaza una de mentira en NGINX (`AUTH0_DOMAIN=http://auth.localhost:${HTTP_PORT}`): la búsqueda devuelve siempre a `alice` y `bob` sin filtrar por nombre, y cualquier `auth0|<nombre>` existe.
- La clave de firma viene dentro de la imagen del servidor de prueba (es pública): no sirve para nada fuera de este entorno.
- Dentro de un contenedor, `curl` también resuelve `*.localhost` a sí mismo; los servicios (Java) usan el DNS de compose y no tienen el problema. Para probar a mano desde un contenedor: `curl --resolve auth.localhost:8088:$(getent hosts auth.localhost | cut -d' ' -f1) ...`.

## Tests de la API

`api-tests/` es una colección de [Bruno](https://www.usebruno.com) que recorre la API pública por NGINX contra el sistema completo: autenticación, CRUD de snippets, compartir, tests de snippets, reglas, formato y descarga, incluidos los flujos asíncronos por Redis (lint, formato y US-16), que se esperan con un sondeo. Necesita el login local.

```sh
COMPOSE_FILE=$COMPOSE_FILE:docker-compose.local-auth.yml docker-compose up -d
dev/api-tests.sh                                 # bru viene en el dev shell
dev/api-tests.sh --reporter-junit results.xml   # además, un reporte JUnit
```

- Cada corrida entra con usuarios nuevos (`owner-<runId>` y `reader-<runId>`): arrancan con las reglas por defecto y sin snippets, así se puede correr las veces que haga falta, sin limpiar nada.
- Las carpetas dependen de las anteriores (tokens y el snippet creado en `02-snippets`): se corre la colección entera, en orden.
- Desde la app de Bruno: abrir la carpeta `api-tests` y elegir el ambiente `local` (supone `HTTP_PORT=8088`; si no, cambiar `baseUrl` y `authUrl`).
- Para Postman, Bruno exporta la colección (*Export → Postman Collection*).

| Carpeta | Qué prueba |
|---|---|
| `01-auth` | `/health` sin token, `401` sin token o con uno inválido, tokens de los dos usuarios |
| `02-snippets` | Crear (válido, inválido con diagnósticos, sin nombre, versión inexistente), lint por Redis hasta `compliant`, obtener, listar, filtrar, actualizar, `404` y `400` |
| `03-compartir` | Buscar usuarios, compartir (también con un usuario inexistente y dos veces), lo que el lector puede (leer, listar, descargar) y no puede (editar, borrar, compartir) |
| `04-tests` | Crear, listar, correr (`success` / `fail`, guardado y sin guardar), último resultado, editar, permisos del lector, US-16 (modificar el snippet vuelve a correr sus tests), borrar |
| `05-reglas` | Reglas por defecto, `/format`, descarga original y formateada, cambio de lint (`not-compliant` y vuelta a `compliant`) y de formato (la versión formateada cambia) |
| `06-limpieza` | Borrar el snippet: desaparece para los dos usuarios, con sus tests |

## Migrar a GitHub

```sh
gh repo create <owner>/snippet-searcher-infra --private --source . --remote origin
git push -u origin dev prod
gh repo edit <owner>/snippet-searcher-infra --default-branch dev
```

CI (`ci.yml`) valida los archivos de compose en cada pull request.
