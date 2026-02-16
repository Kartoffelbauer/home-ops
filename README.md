# HOME-OPS 🚀

A modern, containerized Home-Ops stack designed for **Raspberry Pi**. This project migrates a legacy bare-metal setup into a hardened Docker infrastructure using **Traefik v3** as a reverse proxy, SSL termination, and security gateway.

## 🏗️ Architecture
The setup follows a "Secure-by-Design" principle:
* **Gateway:** Traefik v3 (running as a non-root user with minimal capabilities).
* **Security:** Centralized HSTS, Anti-Sniffing, and Anti-Indexing headers via Traefik Middleware.
* **Network Isolation:** Public-facing apps use `traefik-public`, while backend communication (databases/cache) is isolated within `internal-stack`.
* **Hardening:** Containers use `no-new-privileges` and specific `PUID/PGID` mapping.



---

## 📂 Project Structure
```text
home-ops
├── apps
│   ├── adminer                   # Database Management
│   ├── ocis                      # ownCloud Infinite Scale
│   ├── roundcube                 # Webmail client
│   ├── website-aaronsoft         # Static HTML Site
│   └── website-get-orga-niced    # Static HTML Site
├── core
│   └── traefik
│       ├── acme.json             # SSL Certificates (Stored securely)
│       ├── docker-compose.yml    # Traefik Infrastructure
│       └── traefik_dynamic.yml   # Security Headers & SSL Hardening
├── .env                          # Central Configuration (Secrets & IDs)
├── .gitignore                    # Prevents leaking secrets/data
└── LICENSE
