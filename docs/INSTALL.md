# Installing SpoolSync

This guide covers a self-hosted install with Docker Compose. For a reference
of every setting, see [CONFIGURATION.md](CONFIGURATION.md).

- [Requirements](#requirements)
- [Quick install (wizard)](#quick-install-wizard)
- [Manual install](#manual-install)
- [Before you install: what to decide](#before-you-install-what-to-decide)
- [First run](#first-run)
- [Reverse proxy & HTTPS](#reverse-proxy--https)
- [Updating](#updating)
- [Backup & restore](#backup--restore)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Requirement | Notes |
| --- | --- |
| Linux host (amd64 or arm64) | Any distro that runs Docker. macOS/Windows with Docker Desktop also work. |
| Docker Engine 20.10+ | <https://docs.docker.com/engine/install/> |
| Docker Compose v2 | The `docker compose` plugin (or standalone `docker-compose`). |
| Docker permissions | Your user must be able to run `docker` without `sudo`: `sudo usermod -aG docker $USER`, then log out and back in. |
| `git`, `bash` 4+ | To clone the repo and run the wizard. |
| ~1 GB disk, 1 GB RAM | Building from source needs more temporarily (Node build). |
| Free ports | `80` (web UI) and `3000` (API) by default; both configurable. |

The stack consists of three containers:

```
browser ──► frontend (nginx, :80) ──/api, /socket.io──► backend (Node, :3000) ──► postgres
ESP32 spool holders ─────────────────────────────────► backend (:3000)
```

---

## Quick install (wizard)

```sh
git clone https://github.com/Spool-Sync/SpoolSync-App.git
cd SpoolSync-App
./install.sh
```

The wizard:

1. Checks that Docker and Compose are installed and usable by your user.
2. Asks for:
   - the hostname or IP for SpoolSync, plus bind addresses and ports for the
     web UI and the API (it lists this host's IPs). If the host has a
     macvlan/ipvlan Docker network, the wizard can instead give the web UI
     and API their own LAN IPs (see
     [LAN networking](CONFIGURATION.md#lan-networking-macvlan--ipvlan));
   - the host or IP ESP32 devices should connect to;
   - the database: bundled, or an external PostgreSQL server (host, port,
     name, user), and optionally publishing the bundled one on a host
     IP/port;
   - secrets, session lifetime and the admin account. **Press Enter on any
     secret to have a strong random value generated.**
3. Optionally asks for advanced settings (public URL for a reverse proxy,
   printer polling, syslog, Browserless, prebuilt images).
4. Shows a summary, writes `.env` (mode `600`), builds and starts the stack,
   waits for the backend to be healthy and creates the admin account.
5. Prints the URL and, if it was generated, the admin password (**shown
   once**).

Re-running `./install.sh` later reuses the current `.env` as defaults (secrets
are kept unless you type new ones) and backs up the old file to
`.env.bak.<timestamp>`.

### Non-interactive use

```sh
# Accept all defaults, generating every secret:
./install.sh --yes

# Preset values through the environment:
FRONTEND_PORT=8080 ADMIN_EMAIL=me@example.com ./install.sh --yes

# Only write .env, don't start anything:
./install.sh --no-start
```

Run `./install.sh --help` for the full list of presettable variables.

---

## Manual install

```sh
git clone https://github.com/Spool-Sync/SpoolSync-App.git
cd SpoolSync-App
cp .env.example .env
```

Edit `.env` and at minimum replace both secrets:

```sh
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD='$(openssl rand -hex 24)'|" .env
sed -i "s|^JWT_SECRET=.*|JWT_SECRET='$(openssl rand -hex 48)'|" .env
chmod 600 .env
```

Build and start:

```sh
docker compose up -d --build
```

Create the default roles and the first admin account. Without this step there
is **no account to log in with**:

```sh
docker compose exec \
  -e SEED_ADMIN_EMAIL=you@example.com \
  -e SEED_ADMIN_USERNAME=admin \
  -e SEED_ADMIN_PASSWORD='a-strong-password' \
  backend node prisma/seed.js
```

If you omit the `SEED_ADMIN_*` variables the account is
`admin@spoolsync.local` / `admin123`. Change that password right away.

> **Prebuilt images:** `docker-compose.yml` references
> `ghcr.io/spool-sync/spoolsync-{backend,frontend}`. If those packages are
> not public, `docker compose pull` fails with `unauthorized`; build from
> source as shown above, or `docker login ghcr.io` with a token that has
> access.

---

## Before you install: what to decide

| Decision | Why it matters | Where |
| --- | --- | --- |
| **Database password** | Fixed when the database volume is first created. Changing it later is a manual step. | `POSTGRES_PASSWORD` |
| **Session secret** | Anyone who knows it can forge logins. Changing it logs everyone out. | `JWT_SECRET` |
| **Admin account** | The seed script's defaults (`admin@spoolsync.local` / `admin123`) are public. | wizard / `SEED_ADMIN_*` |
| **Web UI port** | Port 80 may already be taken (another web server, reverse proxy). | `FRONTEND_PORT` |
| **API exposure** | ESP32 spool holders post weights straight to the backend on port 3000. If you don't use them, you can bind it to `127.0.0.1`. | `BACKEND_BIND`, `BACKEND_PORT` |
| **HTTPS** | Phone NFC scanning (Web NFC), ESP32 USB provisioning (Web Serial) and OIDC login only work over HTTPS. Plan a reverse proxy if you want those. | [below](#reverse-proxy--https) |
| **Hostname / IPs** | The name people use to reach SpoolSync, and which host interfaces each service listens on. On multi-homed hosts, bind to one LAN IP rather than `0.0.0.0`. | `SPOOLSYNC_HOSTNAME`, `*_BIND` |
| **Host ports or own LAN IPs** | By default SpoolSync publishes ports on the host's IP. On hosts with a macvlan/ipvlan network, the web UI and API can get their own fixed LAN addresses instead. | `SPOOLSYNC_NETWORK_MODE`, `*_LAN_IP`, [CONFIGURATION.md](CONFIGURATION.md#lan-networking-macvlan--ipvlan) |
| **ESP32 server host** | Spool holders are given a host to report to when provisioned. By default that's the hostname in your browser's address bar, which devices may not resolve. Set an IP. | `ESP32_SERVER_HOST` |
| **Database location** | Bundled container (default) or an existing PostgreSQL server. Optionally publish the bundled one for backup tools. | `POSTGRES_HOST` & co., [CONFIGURATION.md](CONFIGURATION.md#database) |
| **Public URL** | Behind a reverse proxy, fixes the OIDC callback to your public `https://` address. | `PUBLIC_URL` |
| **Session lifetime** | Default 7 days. | `JWT_EXPIRES_IN` |
| **Printer polling** | Default every 30 s. | `PRINTER_POLL_INTERVAL_MS` |

Everything else (OIDC/SSO, users, roles, printers, storage locations, ESP32
devices) is configured in the web UI after first login.

---

## First run

1. Open `http://<host>` (add `:<port>` if not 80).
2. Log in with the admin email and password.
3. **Settings:** configure OIDC single sign-on if wanted (needs HTTPS).
4. **Users / Roles:** create accounts. The seed creates three roles:
   *Administrator* (everything), *Editor* (everything except users, roles and
   settings) and *Viewer* (read-only).
5. **Printers:** add PrusaLink printers by address and API key.
6. **ESP32 Devices → Provision Device:** connect a spool holder by USB (Chrome
   or Edge, over HTTPS) to send it Wi-Fi credentials and the server hostname.

> **Note:** the API endpoint `POST /api/v1/users/register` is open to
> anyone who can reach the server. Accounts created that way have no roles
> (and so no permissions) until an admin grants some. Still, don't expose
> SpoolSync to the internet without a reverse proxy or VPN in front.

---

## Reverse proxy & HTTPS

Put a TLS-terminating proxy (Caddy, Traefik, nginx, Nginx Proxy Manager, …)
in front of the **frontend** container. It already proxies `/api` and
`/socket.io` to the backend.

1. Bind the web UI to localhost so it is only reachable through the proxy.
   Choose a free port. In `.env`:

   ```sh
   FRONTEND_BIND='127.0.0.1'
   FRONTEND_PORT='8080'
   ```

   Then `docker compose up -d`.

2. Proxy your hostname to `http://127.0.0.1:8080`. The proxy must:
   - support WebSockets (`Upgrade`/`Connection` headers) for `/socket.io/`;
   - pass `Host` (or `X-Forwarded-Host`) and `X-Forwarded-Proto: https`. The
     backend builds the OIDC callback URL from these, unless you set
     `PUBLIC_URL='https://spoolsync.example.com'` in `.env` (wizard:
     Advanced → Public URL). That's the simplest fix if your proxy rewrites
     headers.

   Caddy example:

   ```caddyfile
   spoolsync.example.com {
       reverse_proxy 127.0.0.1:8080
   }
   ```

   nginx example:

   ```nginx
   server {
       listen 443 ssl;
       server_name spoolsync.example.com;
       # ssl_certificate ...; ssl_certificate_key ...;

       location / {
           proxy_pass http://127.0.0.1:8080;
           proxy_http_version 1.1;
           proxy_set_header Host $host;
           proxy_set_header X-Forwarded-Proto $scheme;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
       }
   }
   ```

3. For OIDC, register the redirect URI
   `https://<your-host>/api/v1/auth/oidc/callback` with your identity
   provider, then enter the issuer, client ID and secret under **Settings**.

Keep `BACKEND_BIND='0.0.0.0'` (or a LAN IP) if ESP32 devices need to reach
port 3000. They talk to the backend directly, not through the proxy, so set
`ESP32_SERVER_HOST` to the host's LAN IP. A proxy hostname like
`spoolsync.example.com` may resolve to a different machine, or not resolve at
all, on the devices' network.

---

## Updating

```sh
cd SpoolSync-App
git pull
docker compose up -d --build        # or: docker compose pull && docker compose up -d
```

The backend applies schema changes on start-up. If Prisma refuses a change
because it would drop data, the backend exits with a message in
`docker compose logs backend`. Back up first, then decide how to proceed.

> Printer integration definitions live in the `integrations_data` volume,
> which is filled from the image only when it is first created. New or
> updated files in `backend/integrations/printers/` don't appear in an
> existing install automatically. Copy them in with
> `docker compose cp backend/integrations/printers/. backend:/app/integrations/printers/`.

---

## Backup & restore

Back up the database and `.env`:

```sh
docker compose exec -T postgres pg_dump -U spoolsync -Fc spoolsync > spoolsync-$(date +%F).dump
cp .env env-backup
```

Restore into a fresh install (after `docker compose up -d`):

```sh
docker compose stop backend
docker compose exec -T postgres pg_restore -U spoolsync -d spoolsync --clean --if-exists < spoolsync-YYYY-MM-DD.dump
docker compose start backend
```

---

## Uninstalling

```sh
docker compose down                      # stop and remove containers, keep data
docker compose down -v --rmi all         # also delete the database volumes and images
```

`-v` permanently deletes all SpoolSync data. `--rmi all` also removes the
`postgres:16-alpine` image, so leave it off if other stacks use that image.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `permission denied … /var/run/docker.sock` | Add your user to the `docker` group and log in again. |
| `docker compose pull` → `unauthorized` | The ghcr.io images aren't public. Build from source (`up -d --build`) or `docker login ghcr.io`. |
| Login always fails right after install | No admin account yet. Run the seed command from [Manual install](#manual-install). |
| Backend log: `The table … does not exist` | An old image is running `prisma migrate deploy` without migrations. Rebuild from this version (`up -d --build`). |
| Backend log: `Authentication failed against database server` | `POSTGRES_PASSWORD` differs from the one the volume was created with. Restore the old value, or change it in Postgres: `docker compose exec postgres psql -U spoolsync -c "ALTER USER spoolsync PASSWORD 'new'"`. |
| `Bind for 0.0.0.0:80 failed: port is already allocated` | Change `FRONTEND_PORT` (or `BACKEND_PORT`) in `.env`. |
| NFC button / USB provisioning missing | They need HTTPS and a supporting browser (Chrome on Android for NFC; desktop Chrome or Edge for Web Serial). |
| OIDC login loops back to the login page | Must be served over HTTPS (the state cookie is `Secure`). The redirect URI must match exactly. |
| ESP32 device never reports | It must reach `<host-it-was-provisioned-with>:3000`. Set `ESP32_SERVER_HOST` to the host's LAN IP and re-provision. Check `BACKEND_BIND`/`BACKEND_PORT` and your firewall. |
| `cannot assign requested address` when starting | A `*_BIND` address isn't assigned to this host. Use `0.0.0.0`, `127.0.0.1` or one of the IPs from `ip -4 addr`. |
| LAN mode: other devices reach SpoolSync, but the host can't | Normal for macvlan. The host needs a shim interface (a macvlan on the same parent with a route to the containers' range) to talk to its own containers. |
| LAN mode: `Address already in use` / IP conflict on the LAN | Another device has the address. Pick one inside the network's `--ip-range`, away from the router's DHCP pool, and re-run the wizard. |
| Backend can't reach an external database | `POSTGRES_HOST` must be reachable from inside the container. `localhost` is the container itself, so use the host's LAN IP. Also check `pg_hba.conf` and `listen_addresses` on the server. |
