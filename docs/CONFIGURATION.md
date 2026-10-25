# Configuration reference

SpoolSync is configured in two places:

1. **`.env`** in the project directory. Docker Compose reads it automatically.
   It holds deployment settings: secrets, ports and polling. Create it with
   `./install.sh`, or copy `.env.example`. Apply changes with
   `docker compose up -d`.
2. **The web UI.** Runtime settings live in the database: OIDC/SSO, users,
   roles, printers, storage locations, ESP32 devices and display preferences.

Values in `.env` are single-quoted (`KEY='value'`) so Compose does not expand
`$` inside them.

## `.env` settings

### Secrets — set before first run

| Variable | Default | Description |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | `spoolsync_dev` (insecure) | Password of the `spoolsync` database user. Embedded in the backend's connection URL, so use URL-safe characters only (`A-Z a-z 0-9 . _ ~ -`). **Only applied when the `postgres_data` volume is first created.** See [Changing the database password](#changing-the-database-password). |
| `JWT_SECRET` | `change_this_in_production` (insecure) | HMAC key that signs login tokens and the OIDC state cookie. Use 32+ random characters (`openssl rand -hex 48`). Changing it logs out every user. |

The wizard generates both randomly unless you type your own.

### Hostnames & addresses

| Variable | Default | Description |
| --- | --- | --- |
| `SPOOLSYNC_HOSTNAME` | *(empty)* | Name or IP people use to reach SpoolSync. The wizard uses it for its output and as the default for the settings below. The app itself doesn't read it. |
| `PUBLIC_URL` | *(empty)* | Public base URL, e.g. `https://spoolsync.example.com`. When set, the backend builds the OIDC callback (`<PUBLIC_URL>/api/v1/auth/oidc/callback`) from it instead of from the request's `Host`/`X-Forwarded-*` headers. Set it when a reverse proxy doesn't forward those headers correctly. |
| `ESP32_SERVER_HOST` | *(empty)* | Default host/IP that the ESP32 provisioning dialog sends to spool holders. It is served at `GET /api/client-config` and can still be edited in the dialog. Empty means the hostname in the browser's address bar, which devices may not be able to resolve (mDNS names, a proxy hostname). An IP address is safest. |

### Network

Bind addresses must be `0.0.0.0` (all interfaces), a loopback address, or an
IPv4 address assigned to the host. Docker refuses to publish on anything else.

| Variable | Default | Description |
| --- | --- | --- |
| `FRONTEND_BIND` | `0.0.0.0` | Host interface for the web UI. Set to `127.0.0.1` when a reverse proxy on the same host serves it, or to one LAN IP on a multi-homed host. |
| `FRONTEND_PORT` | `80` | Host port of the web UI (nginx; it proxies `/api` and `/socket.io` to the backend). |
| `BACKEND_BIND` | `0.0.0.0` | Host interface for the API. `127.0.0.1` hides it from the network; the UI still works through nginx, but ESP32 devices can't connect. If you bind a specific IP, set `ESP32_SERVER_HOST` to that IP. |
| `BACKEND_PORT` | `3000` | Host port of the backend API. ESP32 spool holders connect here directly. Keep `3000` unless your firmware is set up for another port. |

Inside the Compose network the backend always listens on `3000`, and nginx
always reaches it at `backend:3000`. These settings only change the
published host ports.

### Database

| Variable | Default | Description |
| --- | --- | --- |
| `POSTGRES_HOST` | `postgres` | Database host the backend connects to. `postgres` is the bundled container. For an external server, use its hostname or LAN IP: inside the container, `localhost` means the container itself. |
| `POSTGRES_PORT` | `5432` | Database port the backend connects to. |
| `POSTGRES_DB` | `spoolsync` | Database name. The bundled container creates it only when its volume is first initialised. |
| `POSTGRES_USER` | `spoolsync` | Database user. The bundled container creates it only when its volume is first initialised. |
| `POSTGRES_PUBLISH_BIND` | `127.0.0.1` | Host interface for the bundled database, when `compose/publish-db.yml` is enabled. |
| `POSTGRES_PUBLISH_PORT` | `5432` | Host port for the bundled database, when `compose/publish-db.yml` is enabled. |
| `SPOOLSYNC_DB_MODE`, `POSTGRES_PUBLISH` | `bundled`, `n` | Used only by `install.sh` to remember your choices. |

**External database.** Point `POSTGRES_HOST`/`POSTGRES_PORT`/`POSTGRES_DB`/
`POSTGRES_USER`/`POSTGRES_PASSWORD` at an existing server (the database
and user must already exist). Then enable the overlay that removes the
bundled container (needs Compose 2.24+):

```sh
COMPOSE_FILE='docker-compose.yml:compose/external-db.yml'
COMPOSE_PATH_SEPARATOR=':'
```

**Publishing the bundled database** for backup or admin tools:

```sh
COMPOSE_FILE='docker-compose.yml:compose/publish-db.yml'
COMPOSE_PATH_SEPARATOR=':'
```

The wizard sets these for you. After an existing install switches to an
external database, Compose stops managing the old bundled container; remove
it with `docker rm -f <project>-postgres-1`. Its data volume is kept until
you delete it.

### Sessions

| Variable | Default | Description |
| --- | --- | --- |
| `JWT_EXPIRES_IN` | `7d` | Lifetime of a local (email/password) login: a number plus `s`, `m`, `h`, `d`, `w` or `y`. OIDC logins always last 7 days. Tokens are stateless, so logging out only discards the token in the browser. |

### Printers

| Variable | Default | Description |
| --- | --- | --- |
| `PRINTER_POLL_INTERVAL_MS` | `30000` | How often all printers are polled for status and job progress. |
| `SYSLOG_HOST` | *(empty)* | When set, pushed as the syslog destination to printers running the SpoolSync "buddy" PrusaLink firmware during auto-configuration. |
| `BROWSERLESS_URL` | *(empty)* | WebSocket endpoint of a [Browserless](https://www.browserless.io/) headless Chrome, used by the work-in-progress PrusaConnect login. Not needed for PrusaLink. |

### Images

| Variable | Default | Description |
| --- | --- | --- |
| `SPOOLSYNC_TAG` | `latest` | Tag of the `ghcr.io/spool-sync/spoolsync-{backend,frontend}` images. Images built locally get this tag too. Pinning a version (e.g. `1.2.0`) makes `docker compose pull` predictable. |
| `SPOOLSYNC_IMAGE_SOURCE` | `build` | Used only by `install.sh`: `build` from this checkout, or `pull` prebuilt images. |

### Advanced: Compose-level overrides

| Variable | Description |
| --- | --- |
| `COMPOSE_PROJECT_NAME` | Prefix for container, network and volume names. The default is the directory name (e.g. `spoolsync-app`). Changing it on an existing install points Compose at **new, empty** volumes. |
| `COMPOSE_FILE` | Colon-separated list of Compose files (see [Database](#database)). Once set, Compose no longer loads `docker-compose.override.yml` automatically, so add it at the end of the list. The wizard does this when the file exists. |

For anything else, such as extra networks or resource limits, create a
`docker-compose.override.yml`. Compose merges it automatically, and git
ignores it. Passwords with characters outside `A-Z a-z 0-9 . _ ~ -` can be
used by overriding the whole `DATABASE_URL` there, percent-encoded:

```yaml
services:
  backend:
    environment:
      DATABASE_URL: postgresql://user:p%40ss@db.example.com:5432/spoolsync?schema=public
```

## Fixed settings (in the images)

| Setting | Value | Where to change |
| --- | --- | --- |
| `NODE_ENV` | `production` | `docker-compose.yml`. Production marks cookies `Secure` and hides stack traces. |
| nginx upstream | `BACKEND_HOST=backend` | Environment of the `frontend` container (useful in Kubernetes) |
| Filament database | `api.openfilamentdatabase.org` | Built in. Needs outbound HTTPS from the backend. |

## Initial admin account (seed)

`backend/prisma/seed.js` creates the *Administrator*, *Editor* and *Viewer*
roles and a super-admin account. It **does not run automatically**:
`install.sh` runs it, or you run it by hand:

```sh
docker compose exec \
  -e SEED_ADMIN_USERNAME=admin \
  -e SEED_ADMIN_EMAIL=you@example.com \
  -e SEED_ADMIN_PASSWORD='a-strong-password' \
  backend node prisma/seed.js
```

| Variable | Default |
| --- | --- |
| `SEED_ADMIN_USERNAME` | `admin` |
| `SEED_ADMIN_EMAIL` | `admin@spoolsync.local` |
| `SEED_ADMIN_PASSWORD` | `admin123` |

The seed is safe to re-run. It refreshes the role permissions. If the email
already exists, that user's password is **not** changed.

## Web UI settings

| Area | What you configure |
| --- | --- |
| Settings → OIDC | Issuer URL, client ID, client secret, enable/disable. Redirect URI: `https://<host>/api/v1/auth/oidc/callback`. Group/role claims (`groups` or `roles`) map to SpoolSync roles, which an admin must grant permissions to. Requires HTTPS. |
| Users / Roles | Local accounts, custom roles and permissions. |
| Printers | PrusaLink / PrusaConnect printers and their spool-holder slots. |
| ESP32 Devices | Provision spool holders over USB (Web Serial, HTTPS). Each device gets Wi-Fi credentials and the hostname from your address bar. |
| Storage locations, filament types, orders | Inventory data. |

## Changing the database password

The Postgres image applies `POSTGRES_PASSWORD` only when it initialises an
empty volume. To change it later:

```sh
docker compose exec postgres psql -U spoolsync -c "ALTER USER spoolsync PASSWORD 'new-password'"
# then set POSTGRES_PASSWORD='new-password' in .env and:
docker compose up -d
```

## Database schema

The repository does not ship Prisma migration files. On start-up the backend
runs `prisma migrate deploy` if `prisma/migrations/` exists in the image.
Otherwise it runs `prisma db push`, which syncs the schema and refuses
changes that would lose data.
