# Home-Ops 🏠

A modular, secure, and "clean-code" Docker stack for self-hosting applications and static websites. This project uses **Traefik** as a reverse proxy with automatic SSL and **SFTPGo** as a centralized file management gateway.

## 📂 Project Structure

```text
home-ops/
├── apps/                  # Application stacks (Websites, Adminer, etc.)
├── core/                  # Infrastructure (Traefik, SFTPGo)
├── docker-compose.yml     # Master compose file (includes sub-files)
└── .env                   # Global configuration
```

## 🚀 Prerequisites

* Docker & Docker Compose
* `apache2-utils` (to generate password hashes)

## 🛠️ Setup & Installation

### 1. Global Configuration
Create the master environment file from the example.

```bash
cp .env.example .env
```

Edit `.env` and configure the following:
* **PUID/GUID**: Your personal User ID and Group ID (usually `1000`).
* **SOCKET_GID**: The group ID of the docker group (`getent group docker | cut -d: -f3`).
* **ACME_EMAIL**: Your email address for Let's Encrypt notifications.

### 2. Service Configuration
You must create `.env` files for Traefik and your apps.

**Traefik:**
```bash
cd core/traefik
cp .env.example .env
# Edit .env: Set DASHBOARD_HOST_RULE and DASHBOARD_CREDENTIALS
```
*Note: Generate credentials with `htpasswd -nb user password`. Double the `$$` signs in the hash.*

**Apps & Websites:**
Navigate to each app in `apps/` (e.g., `apps/website-aaronsoft`) and create their `.env` files to define their domains (`HOST_RULE`).

### 3. SSL Storage
Create the file for SSL certificates and secure it.

```bash
touch core/traefik/acme.json
chmod 600 core/traefik/acme.json
```

### 4. Start the Stack
From the root `home-ops` directory:

```bash
docker compose up -d
```

## 🔐 Security Features

This stack is hardened by default:
* **Read-Only Containers**: Apps run with read-only filesystems.
* **Least Privilege**: Apps run as non-root users (`PUID:GUID`) with capabilities dropped (`cap_drop: ALL`).
* **Traefik Middlewares**:
    * `sec-base`: Strict headers (HSTS, Anti-Sniffing) for public sites.
    * `sec-apps`: Adds robot blocking and stricter rules for internal tools (Adminer).
    * `dashboard-auth`: Basic Auth protection.

## 📂 SFTP File Management

A centralized SFTP gateway runs on **Port 2222**.

* **Host**: `your-server-ip`
* **Port**: `2222`
* **Users**: Defined in `core/sftpgo/users.json`.

To add new SFTP users or websites, edit `core/sftpgo/users.json` and map the new volumes in `core/sftpgo/docker-compose.yml`.