![title](https://github.com/user-attachments/assets/7a6f979d-91c9-4696-a6d2-1c60212457d5)<?xml version="1.0" encoding="UTF-8" standalone="no"?>

[Official Website](https://spool-sync.com/)

**SpoolSync** is an advanced, user-friendly filament management platform for 3D printing enthusiasts and print farms. It provides real-time tracking, inventory management, and seamless integration with printers and hardware, all in a self-hosted, privacy-first package.

![Dashboard](docs/screenshots/dashboard.png)

---

## Key Features

- **Live Weight Tracking:**

  ![Scales / Spool Holders](docs/screenshots/scales.png)

  - ESP32-based load cells report spool weights in real time over Wi-Fi.
  - Instantly see filament usage as your printer runs.

- **NFC Tag Scanning & Filament Inventory:**

  ![Filament Inventory](docs/screenshots/spools.png)

  - Tap a spool with your phone to view details or start the ingest flow.
  - Supports OpenPrintTag, Bambu, and serial tags.

- **Printer Integration:**

  ![Printers](docs/screenshots/printers.png)

  - Polls PrusaLink and PrusaConnect [Work In Progress] for live print job status.
  - Automatically deducts filament when a job completes.

- **Storage Locations:**

  ![Storage](docs/screenshots/storage.png)

  - Organize spools into drying chambers, long-term storage, or open shelves.
  - Always know where every spool is stored.

- **Smart Inventory Alerts & Ordering:**

  ![Inventory](docs/screenshots/inventory.png)

  ![Orders](docs/screenshots/orders.png)

  - Set reorder thresholds per filament type.
  - Track orders from placement through delivery.

- **Weigh & Ingest Flow:**

  ![Weigh](docs/screenshots/weigh.png)

  - Quickly weigh a spool on any connected scale and ingest it into your library.
  - Full NFC + scale workflow in a single step.

- **ESP32 Device Management:**

  ![ESP32 Devices](docs/screenshots/esp32.png)

  - Provision and monitor all your ESP32 spool holder devices from one place.
  - View per-device calibration and connectivity status.

- **Settings & OIDC SSO:**

  ![Settings](docs/screenshots/settings.png)

  - Configure OIDC single sign-on (Authentik, Keycloak, Google Workspace, etc.).
  - All admin settings are managed through the UI — no env-var fiddling required.

- **Self-Hosted & Private:**
  - Deploy with Docker Compose in under five minutes.
  - No subscriptions, no cloud lock-in, no telemetry.

---

## Architecture

- **Backend:** Node.js (Express), Prisma ORM, Socket.IO for real-time updates
- **Frontend:** Vue.js (Vuetify UI)
- **Firmware:** ESP32 (C++/Arduino) for load cell and NFC-enabled spool holders
- **Integrations:** Modular JSON-based printer integrations (e.g., PrusaConnect)

---

## Getting Started

You need a host with Docker and the Compose plugin, and a user that can run `docker` without `sudo`.

```sh
git clone https://github.com/Spool-Sync/SpoolSync-App.git
cd SpoolSync-App
./install.sh
```

The wizard asks for ports, secrets and the admin account. Press Enter on a secret to have a strong random value generated. It then writes `.env`, builds and starts the stack, and creates your admin login. When it finishes, open the URL it prints.

- **[Installation guide](docs/INSTALL.md)**: manual install, what to decide before the first run, HTTPS/reverse proxy, updating, backups, troubleshooting.
- **[Configuration reference](docs/CONFIGURATION.md)**: every `.env` setting and what is configured in the UI instead.

Manual quick start, if you'd rather not use the wizard:

```sh
cp .env.example .env    # then replace POSTGRES_PASSWORD and JWT_SECRET
docker compose up -d --build
docker compose exec -e SEED_ADMIN_EMAIL=you@example.com -e SEED_ADMIN_PASSWORD='change-me' \
  backend node prisma/seed.js   # creates roles + the first admin account
```

---

## Project Structure

- `backend/` — Node.js API, integrations, database
- `frontend/` — Vue.js SPA
- `firmware/` — ESP32 firmware for spool holder hardware

---

## Documentation

- **API:** See `backend/prisma/schema.prisma` and backend source
- **Integrations:** See `backend/integrations/printers/` for JSON config examples

---

## License

This project is licensed under the [GPL-3.0 License](LICENSE).

---

## Contributing

Pull requests and issues are welcome! Open an issue to get started.

---

## Credits

- Inspired by Spoolman and the Open Print Tag project
