# Home-Ops 🏠

A modular, secure Docker Compose stack for self-hosting applications and infrastructure. This project uses Traefik as a reverse proxy with automated SSL and focuses heavily on container security principles, including least privilege, non-root execution, and read-only filesystems.

## 📂 Project Structure

The stack is modular, splitting services into logical domains:

```text
.
├── apps/                  # End-user facing applications
│   ├── home-assistant/    # Smart Home automation (host network)
│   ├── ocis/              # ownCloud Infinite Scale & OnlyOffice
│   ├── roundcube/         # Webmail client
│   └── websites/          # Nginx-based static sites
├── core/                  # Infrastructure & backend services
│   ├── database/          # MariaDB & Adminer
│   ├── routing/           # Traefik Reverse Proxy & Gandi DDNS Updater
│   └── system/            # Watchtower (auto-updates) & Fallback error pages
├── shared/                # Global DRY configurations
│   └── templates.yml      # Base templates enforcing project-wide security standards
├── data-manager.sh        # System administration script for backups and restores
└── docker-compose.yml     # Master entrypoint importing all modular sub-services

```

## 🚀 Prerequisites

* Docker and Docker Compose plugin installed.
* `apache2-utils` (or equivalent) for generating `htpasswd` hashes.
* A configured domain and relevant API tokens (e.g., Gandi) if utilizing the default DNS challenge setup.
* UFW (Uncomplicated Firewall) enabled on the host machine.

## 🛠️ Quick Start

1. **Configure the Environment**

    Copy the example environment file and fill in your domains, passwords, and tokens.
    ```bash
    cp .env.example .env
    nano .env
    ```

2. **Generate Traefik Credentials**

    Generate a password hash for the Traefik dashboard. Replace `admin` with your preferred username.
    ```bash
    htpasswd -nB admin
    ```

    Copy the output and paste it into the `TRAEFIK_DASHBOARD_CREDENTIALS` variable in your `.env` file. Ensure you escape any `$` symbols by doubling them (e.g., `$$`).

3. **Secure Configuration Files**

    Restrict permissions on your environment file to protect sensitive data.
    ```bash
    chmod 600 .env
    ```

4. **Configure Firewall (UFW)**

    To secure the host architecture under a Least-Privilege model, local core infrastructure is locked down to private networks, while the Edge Proxy handles public traffic entry points.

    Run the following commands to apply the deployment profile:

    ```bash
    # --- Layer 1: Public Edge Proxy (Traefik Inbound) ---
    sudo ufw allow proto tcp from any to any port 80 comment 'Traefik: Web HTTP'
    sudo ufw allow proto tcp from any to any port 443 comment 'Traefik: Web HTTPS (TCP)'
    sudo ufw allow proto udp from any to any port 443 comment 'Traefik: Web HTTPS (UDP/HTTP3)'

    # --- Layer 2: Internal Proxy Routing (Traefik to Host Services) ---
    sudo ufw allow in from 172.16.0.0/12 to 172.17.0.1 port 8123 proto tcp comment 'Allow Traefik to Host Home Assistant'

    # --- Layer 3: Core Infrastructure (Pi-hole Local DNS) ---
    sudo ufw allow from <LAN_IPV4_SUBNET> to <HOST_LAN_IPV4> port 53 proto udp comment 'Pi-hole: IPv4 DNS (UDP)'
    sudo ufw allow from <LAN_IPV4_SUBNET> to <HOST_LAN_IPV4> port 53 proto tcp comment 'Pi-hole: IPv4 DNS (TCP)'
    sudo ufw allow from fe80::/10 to <HOST_IPV6_LINK_LOCAL> port 53 proto udp comment 'Pi-hole: IPv6 DNS (UDP)'
    sudo ufw allow from fe80::/10 to <HOST_IPV6_LINK_LOCAL> port 53 proto tcp comment 'Pi-hole: IPv6 DNS (TCP)'

    # --- Layer 4: Smart Home Discovery (UPnP / SSDP Multicast) ---
    sudo ufw allow in proto igmp to any comment 'UPnP: IGMP Tracking'
    sudo ufw allow in proto udp to 239.255.255.250 port 1900 comment 'UPnP: IPv4 Multicast SSDP'
    sudo ufw allow in proto udp to ff02::c port 1900 comment 'UPnP: IPv6 Multicast SSDP'

    # --- Layer 5: Smart Home Discovery (Inbound Gateway Responses) ---
    sudo ufw allow in proto udp from <LAN_IPV4_SUBNET> port 1900 to <HOST_LAN_IPV4> port 1900 comment 'UPnP: LAN UDP Responses'
    sudo ufw allow in proto tcp from <LAN_IPV4_SUBNET> to <HOST_LAN_IPV4> port 30000:40000 proto tcp comment 'UPnP: LAN TCP Push APIs'
    ```

    *Note: `172.16.0.0/12` encapsulates isolated Docker bridge spaces. The `<HOST_LAN_IPV4>` target points directly to the real host physical interface, matching the requirements for services running in `network_mode: host`. The explicit `fe80::/10` IPv6 link-local rule eliminates multi-second Happy Eyeballs fallback lookup delays on modern client devices.*

    Apply Changes:

    ```bash
    sudo ufw reload
    ```

4. **Start the Stack**

    Initialize and run all services in the background. The setup uses init-containers to automatically handle directory permissions and initial database setups.
    ```bash
    docker compose up -d
    ```

## 💾 Backup and Restore

The repository includes a `data-manager.sh` script to handle cold backups. This script safely stops the containers, archives all dynamically found `data` directories (and the `.env` file) to ensure database consistency, and then restarts the stack.

**Note:** The script must be run as root to preserve correct file ownership and permissions.

### Preparation

Make the script executable (Run Once):

```bash
chmod +x data-manager.sh
```

### Create a Backup

To create a backup archive in a specified destination directory:

```bash
sudo ./data-manager.sh backup /path/to/backup/destination
```

### Restore from a Backup

To restore data from an existing .tar.gz archive (this will overwrite current data):

```bash
sudo ./data-manager.sh restore /path/to/backup/archive/home-ops-backup_YYYY-MM-DD_HH-MM-SS.tar.gz
```