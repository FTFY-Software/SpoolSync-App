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

### Network

| Variable | Default | Description |
| --- | --- | --- |
| `FRONTEND_PORT` | `80` | Host port of the web UI (nginx; it proxies `/api` and `/socket.io` to the backend). |
| `FRONTEND_BIND` | `0.0.0.0` | Host interface for the web UI. Set to `127.0.0.1` when a reverse proxy on the same host serves it. |
| `BACKEND_PORT` | `3000` | Host port of the backend API. ESP32 spool holders connect here directly. Keep `3000` unless your firmware is set up for another port. |
| `BACKEND_BIND` | `0.0.0.0` | Host interface for the API. `127.0.0.1` hides it from the network; the UI still works through nginx, but ESP32 devices can't connect. |

Inside the Compose network the backend always listens on `3000`, and nginx
always reaches it at `backend:3000`. These settings only change the
published host ports.

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

For anything else, such as an external Postgres, extra networks or resource
limits, create a `docker-compose.override.yml`. Compose merges it
automatically, and git ignores it. Example for an external database:

```yaml
services:
  backend:
    environment:
      DATABASE_URL: postgresql://user:pass@db.example.com:5432/spoolsync?schema=public
    depends_on: !reset {}
  postgres:
    profiles: ["disabled"]
```

## Fixed settings (in the images)

| Setting | Value | Where to change |
| --- | --- | --- |
| Database name / user | `spoolsync` / `spoolsync` | `docker-compose.yml` (only before first run) |
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
