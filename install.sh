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

    read -rp "Enter dashboard domain (e.g., dashboard.example.com): " DOMAIN_DASHBOARD
    read -rp "Enter PowerDNS API domain (e.g., pdns.example.com): " DOMAIN_PDNS

    DASH_USER="admin"
    DASH_PASS=$(generate_password)
    PDNS_API_KEY=$(generate_password)
    MYSQL_ROOT_PASSWORD=$(generate_password)
    PDNS_DB_PASSWORD=$(generate_password)

    # Save environment file
    cat > "$ENV_FILE" <<EOF
DOMAIN_DASHBOARD=$DOMAIN_DASHBOARD
DOMAIN_PDNS=$DOMAIN_PDNS

DASH_USER=$DASH_USER
DASH_PASS="$DASH_PASS"

PDNS_API_KEY="$PDNS_API_KEY"

MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD"
PDNS_DB_PASSWORD="$PDNS_DB_PASSWORD"
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
wait_for_http "http://localhost:8081" "PowerDNS API"

# ----------------------------------------
# Wait for Backend
# ----------------------------------------
wait_for_http "http://localhost:8080" "Backend UI"

# ----------------------------------------
# Final summary
# ----------------------------------------
echo ""
echo "============================"
echo " DNSSEC-Manager installation complete!"
echo "============================"
echo ""
echo "Dashboard URL: https://$DOMAIN_DASHBOARD"
echo "Dashboard credentials:"
echo "  Username: $DASH_USER"
echo "  Password: $DASH_PASS"
echo ""
echo "PowerDNS API URL: https://$DOMAIN_PDNS"
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
