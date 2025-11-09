#!/usr/bin/env bash
set -e

INSTALL_DIR="/opt/dnssec-manager"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
SCHEMA_FILE="$INSTALL_DIR/schema.sql"
REPO_BASE="https://raw.githubusercontent.com/DNSSEC-Manager/DNSSEC-Manager/main"

LOG_FILE="$INSTALL_DIR/install.log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "============================"
echo " DNSSEC-Manager Installer"
echo "============================"
echo ""

# ----------------------------------------
# Check root
# ----------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Run as root"
  exit
fi

# ----------------------------------------
# Flags
# ----------------------------------------
REINSTALL=false
UPDATE=false

for arg in "$@"; do
    case $arg in
        --reinstall)
            REINSTALL=true
            ;;
        --update)
            UPDATE=true
            ;;
    esac
done

# ----------------------------------------
# Helper functions
# ----------------------------------------

generate_password() {
    openssl rand -base64 18
}

wait_for_http() {
    local URL="$1"
    local LABEL="$2"

    echo "Waiting for $LABEL to be ready at $URL ..."
    for i in {1..60}; do
        if curl -fs "$URL" >/dev/null 2>&1; then
            echo "$LABEL is ready!"
            return 0
        fi
        printf "."
        sleep 2
    done
    echo ""
    echo "⚠ WARNING: $LABEL did not become ready in time, continuing..."
}

check_port_53() {
  if lsof -i:53 >/dev/null 2>&1; then
    echo "Port 53 is in use. Attempting to stop conflicting service..."
    if systemctl is-active --quiet systemd-resolved; then
      systemctl stop systemd-resolved
      systemctl disable systemd-resolved
      echo "systemd-resolved stopped."
      echo "nameserver 1.1.1.1" > /etc/resolv.conf
      echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    else
      echo "⚠ Port 53 is still in use! Free it manually and rerun."
      exit 1
    fi
  fi
}

# ----------------------------------------
# Prepare installation directory
# ----------------------------------------
if [ "$REINSTALL" = true ]; then
    echo "Reinstall mode: removing existing installation..."
    rm -rf "$INSTALL_DIR"
fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo "Directory $INSTALL_DIR does not exist. Creating..."
    mkdir -p "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

echo "Working in directory: $INSTALL_DIR"

# ----------------------------------------
# Ask user for configuration (wizard)
# ----------------------------------------
if [ ! -f "$ENV_FILE" ] || [ "$REINSTALL" = true ]; then
    echo ""
    echo "Configuration Wizard"
    echo "--------------------"

    #read -rp "Enter Traefik dashboard domain (e.g., traefik.example.com): " TRAEFIK_HOST
    #read -rp "Enter DNSSEC Manager dashboard domain (e.g., dns.example.com): " DOMAIN
    #read -rp "Enter Nameserver NS1 for this server (e.g., ns1.example.com): " DOMAIN_NS1
    #read -rp "Enter Nameserver NS2 for this server (e.g., ns2.example.com): " DOMAIN_NS2
    read -rp "Enter your main domainname to attach to this nameserver (e.g., example.com): " DOMAINNAME
    read -rp "Enter your email for Let's Encrypt: " EMAIL

    TRAEFIK_USER="admin"
    TRAEFIK_PASS=$(generate_password)
    TRAEFIK_AUTH=$(htpasswd -nbB $TRAEFIK_USER $TRAEFIK_PASS | cut -d ":" -f 2)
    # Escape dollar signs for Docker Compose
    TRAEFIK_AUTH_ESCAPED="${TRAEFIK_AUTH//$/\$\$}"
    
    PDNS_API_KEY=$(generate_password)
    PDNS_DB_PASSWORD=$(generate_password)
    MYSQL_ROOT_PASSWORD=$(generate_password)
    
    TRAEFIK_HOST=traefik.$DOMAINNAME
    BACKEND_HOST=dnssecmanager.$DOMAINNAME
    PDNS_HOST=powerdns.$DOMAINNAME

    # Save environment file
    cat > "$ENV_FILE" <<EOF
TRAEFIK_HOST=$TRAEFIK_HOST
TRAEFIK_USER=$TRAEFIK_USER
TRAEFIK_PASS=$TRAEFIK_PASS
TRAEFIK_AUTH="$TRAEFIK_AUTH_ESCAPED"
EMAIL=$EMAIL

BACKEND_HOST=$BACKEND_HOST
DOMAIN_NS1=$DOMAIN_NS1
DOMAIN_NS2=$DOMAIN_NS2

PDNS_HOST=$PDNS_HOST
PDNS_API_KEY="$PDNS_API_KEY"
PDNS_DB_PASSWORD="$PDNS_DB_PASSWORD"
MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
EOF

    echo ".env file created."
else
    echo ".env file exists — using existing configuration."
    source "$ENV_FILE"
fi

# ----------------------------------------
# Check if port 53 is free for PowerDNS
# ----------------------------------------
check_port_53

# ----------------------------------------
# Install Docker if needed
# ----------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | bash
else
    echo "Docker already installed."
fi

# ----------------------------------------
# Install Docker Compose plugin
# ----------------------------------------
if ! docker compose version >/dev/null 2>&1; then
    echo "Installing Docker Compose..."
    mkdir -p /usr/lib/docker/cli-plugins
    curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
        -o /usr/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/lib/docker/cli-plugins/docker-compose
else
    echo "Docker Compose plugin already present."
fi

# ----------------------------------------
# Download compose file and rename
# ----------------------------------------
curl -fsSL "$REPO_BASE/compose.prod.yml" -o compose.prod.yml
mv -f compose.prod.yml "$COMPOSE_FILE"

echo "docker-compose.yml ready."

# ----------------------------------------
# Download schema.sql
# ----------------------------------------

echo "Downloading schema.sql..."
curl -fsSL "$REPO_BASE/schema.sql" -o "$SCHEMA_FILE"
echo "schema.sql downloaded."

# ----------------------------------------
# Update mode
# ----------------------------------------
if [ "$UPDATE" = true ]; then
    echo "Updating images..."
    docker compose pull
    docker compose up -d
    echo "Update complete."
    exit 0
fi

# ----------------------------------------
# Configure firewall (UFW)
# ----------------------------------------
if command -v ufw >/dev/null 2>&1; then
    echo "Configuring firewall with UFW..."

    ufw allow 22/tcp   >/dev/null 2>&1 || true
    ufw allow 80/tcp   >/dev/null 2>&1 || true
    ufw allow 443/tcp  >/dev/null 2>&1 || true

    # DNS ports (public!)
    ufw allow 53/tcp   >/dev/null 2>&1 || true
    ufw allow 53/udp   >/dev/null 2>&1 || true

    # PowerDNS API / Stats
    ufw allow 8081/tcp >/dev/null 2>&1 || true

    # Enable UFW only if not enabled yet
    if ! ufw status | grep -q "Status: active"; then
        echo "Enabling UFW..."
        yes | ufw enable
    fi

    echo "Firewall rules applied."
else
    echo "UFW not installed or not available; skipping firewall configuration."
fi


# ----------------------------------------
# Start stack
# ----------------------------------------
echo "Starting Docker stack..."
docker compose up -d

# --- SYSTEMD SERVICE ---
SERVICE_FILE="/etc/systemd/system/dnssecmanager.service"
cat > $SERVICE_FILE <<EOF
[Unit]
Description=DNSSEC-Manager Stack
After=docker.service
Requires=docker.service

[Service]
WorkingDirectory=$(pwd)
ExecStart=/usr/local/bin/docker compose -f $(pwd)/compose.yml up
ExecStop=/usr/local/bin/docker compose -f $(pwd)/compose.yml down
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dnssecmanager
systemctl start dnssecmanager

# ----------------------------------------
# Wait for PowerDNS
# ----------------------------------------
#wait_for_http "http://localhost:8081" "PowerDNS API"

# ----------------------------------------
# Wait for Backend
# ----------------------------------------
#wait_for_http "http://localhost:8080" "Backend UI"

# ----------------------------------------
# Final summary
# ----------------------------------------
echo ""
echo "============================"
echo " DNSSEC-Manager installation complete!"
echo "============================"
echo ""
echo "DNSSSEC Manager URL: https://$BACKEND_HOST"
echo "Default login:"
echo "  Username: admin"
echo "  Password: ChangeMe123!"
echo ""
echo "Traefik URL: https://$TRAEFIK_HOST"
echo "Traefik credentials:"
echo "  Username: $TRAEFIK_USER"
echo "  Password: $TRAEFIK_PASS"
echo ""
echo "PowerDNS API URL: https://$PDNS_HOST"
echo "PowerDNS API Key: $PDNS_API_KEY"
echo ""
echo "MariaDB root password: $MYSQL_ROOT_PASSWORD"
echo "PowerDNS DB password: $PDNS_DB_PASSWORD"
echo ""
echo "Environment stored in: $ENV_FILE"
echo ""
echo "To manage the stack:"
echo "  cd $INSTALL_DIR"
echo "  docker compose ps"
echo "  docker compose logs -f"
echo ""
