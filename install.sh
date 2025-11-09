#!/usr/bin/env bash
set -e

# ----------------------------
# Logging
# ----------------------------
LOG_FILE="install.log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "============================"
echo " DNSSEC-Manager Installer"
echo "============================"

# ----------------------------
# Configuration directory
# ----------------------------
INSTALL_DIR="/opt/dnssec-manager"

if [ ! -d "$INSTALL_DIR" ]; then
  echo "📂 Directory $INSTALL_DIR does not exist. Creating..."
  mkdir -p "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
echo "✅ Working in directory: $(pwd)"

# ----------------------------
# Helper functions
# ----------------------------
function wait_for_url() {
  local url=$1
  local name=$2
  local retries=${3:-60}
  echo "Waiting for $name to be ready at $url ..."
  until curl -fsS "$url" >/dev/null 2>&1 || [[ $retries -le 0 ]]; do
    echo -n "."
    sleep 2
    ((retries--))
  done
  if [[ $retries -le 0 ]]; then
    echo ""
    echo "⚠ WARNING: $name did not become ready in time, continuing..."
  else
    echo " $name is up!"
  fi
}

function generate_password() {
  openssl rand -base64 16
}

function check_port_53() {
  if lsof -i:53 >/dev/null 2>&1; then
    echo "Port 53 is in use. Attempting to stop conflicting service..."
    if systemctl is-active --quiet systemd-resolved; then
      systemctl stop systemd-resolved
      systemctl disable systemd-resolved
      echo "systemd-resolved stopped."

      # Fix DNS temporarily for curl
      echo "nameserver 1.1.1.1" > /etc/resolv.conf
      echo "nameserver 8.8.8.8" >> /etc/resolv.conf
      echo "✅ Temporary DNS configured for curl."
    else
      echo "⚠ Port 53 is still in use! Please free it manually and rerun."
      exit 1
    fi
  fi
}

# ----------------------------
# Install required tools
# ----------------------------
echo "Updating package index..."
apt update -y

if ! command -v htpasswd >/dev/null; then
  echo "Installing apache2-utils (htpasswd)..."
  apt install -y apache2-utils
fi

if ! command -v curl >/dev/null; then
  echo "Installing curl..."
  apt install -y curl
fi

# ----------------------------
# Wizard prompts
# ----------------------------
read -rp "Enter main domain for backend (e.g., dns.example.com): " DOMAIN
read -rp "Enter dashboard domain (e.g., dashboard.example.com): " DOMAIN_DASHBOARD
read -rp "Enter your email for Let's Encrypt: " EMAIL

read -rp "Enter PowerDNS API key (leave empty to generate random): " PDNS_API_KEY
PDNS_API_KEY=${PDNS_API_KEY:-$(generate_password)}

read -rp "Enter MariaDB root password (leave empty to generate random): " MYSQL_ROOT_PASSWORD
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-$(generate_password)}

read -rp "Enter PowerDNS DB password (leave empty to generate random): " PDNS_DB_PASSWORD
PDNS_DB_PASSWORD=${PDNS_DB_PASSWORD:-$(generate_password)}

read -rp "Enter Traefik dashboard username (leave empty for random): " DASH_USER
DASH_USER=${DASH_USER:-admin}

read -rp "Enter Traefik dashboard password (leave empty for random): " DASH_PASS
DASH_PASS=${DASH_PASS:-$(generate_password)}

# Create bcrypt hash for Traefik Basic Auth
DASH_AUTH=$(htpasswd -nbB "$DASH_USER" "$DASH_PASS" | cut -d ":" -f 2)

# ----------------------------
# Check port 53
# ----------------------------
check_port_53

# ----------------------------
# Install Docker & Compose
# ----------------------------
if ! command -v docker >/dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi

if ! command -v docker-compose >/dev/null; then
  echo "Installing Docker Compose..."
  DOCKER_COMPOSE_VERSION="2.24.2"
  curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# ----------------------------
# Create .env
# ----------------------------
ENV_FILE="$INSTALL_DIR/.env"
cat > "$ENV_FILE" <<EOF
DOMAIN=$DOMAIN
DOMAIN_DASHBOARD=$DOMAIN_DASHBOARD
EMAIL=$EMAIL
PDNS_API_KEY=$PDNS_API_KEY
PDNS_DB_PASSWORD=$PDNS_DB_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
TRAEFIK_DASH_USER=$DASH_USER
TRAEFIK_DASH_PASS=$DASH_PASS
TRAEFIK_DASH_AUTH=$DASH_AUTH
EOF
echo ".env file created at $ENV_FILE"

# ----------------------------
# Download compose file and rename
# ----------------------------
curl -fsSL https://raw.githubusercontent.com/DNSSEC-Manager/DNSSEC-Manager/main/compose.prod.yml -o compose.prod.yml
mv -f compose.prod.yml docker-compose.yml
echo "docker-compose.yml ready"

# ----------------------------
# Optional firewall
# ----------------------------
if command -v ufw >/dev/null; then
  echo "Configuring firewall..."
  ufw allow 53/tcp
  ufw allow 53/udp
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

# ----------------------------
# Start Docker stack
# ----------------------------
echo "Starting Docker stack..."
docker compose up -d

# ----------------------------
# Systemd service
# ----------------------------
SERVICE_FILE="/etc/systemd/system/dnssecmanager.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=DNSSEC-Manager Stack
After=docker.service
Requires=docker.service

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/local/bin/docker compose up
ExecStop=/usr/local/bin/docker compose down
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dnssecmanager
systemctl start dnssecmanager

# ----------------------------
# Healthchecks
# ----------------------------
wait_for_url "http://localhost:8081" "PowerDNS API"
wait_for_url "http://localhost:5000" "Backend UI"

# ----------------------------
# Installation summary
# ----------------------------
echo ""
echo "============================"
echo " DNSSEC-Manager installation complete!"
echo "============================"
echo ""
echo "Backend URL: https://$DOMAIN"
echo "Dashboard URL: https://$DOMAIN_DASHBOARD"
echo "Dashboard credentials: $DASH_USER / $DASH_PASS"
echo "PowerDNS API Key: $PDNS_API_KEY"
echo "MariaDB root password: $MYSQL_ROOT_PASSWORD"
echo "PowerDNS DB password: $PDNS_DB_PASSWORD"
echo ""
echo "✅ All information is stored in $ENV_FILE"
echo "You can check running containers with: docker compose ps"
