#!/usr/bin/env bash
set -e

LOG_FILE="install.log"
exec > >(tee -i $LOG_FILE) 2>&1

echo "============================"
echo " DNSSEC-Manager Installer"
echo "============================"

# --- FUNCTIONS ---
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
    echo "ERROR: $name did not become ready in time!"
    exit 1
  fi
  echo " $name is up!"
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
    else
      echo "WARNING: Port 53 is still in use! Please free it manually and rerun."
      exit 1
    fi
  fi
}

# --- WIZARD ---
read -rp "Enter main domain for backend (e.g., dns.example.com): " DOMAIN
read -rp "Enter dashboard domain (e.g., dashboard.example.com): " DOMAIN_DASHBOARD
read -rp "Enter your email for Let's Encrypt: " EMAIL

read -rp "Enter PowerDNS API key (leave empty to generate random): " PDNS_API_KEY
PDNS_API_KEY=${PDNS_API_KEY:-$(openssl rand -base64 24)}

read -rp "Enter MariaDB root password (leave empty to generate random): " MYSQL_ROOT_PASSWORD
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-$(generate_password)}

read -rp "Enter PowerDNS DB password (leave empty to generate random): " PDNS_DB_PASSWORD
PDNS_DB_PASSWORD=${PDNS_DB_PASSWORD:-$(generate_password)}

read -rp "Enter Traefik dashboard username (leave empty for random): " DASH_USER
DASH_USER=${DASH_USER:-admin}

read -rp "Enter Traefik dashboard password (leave empty for random): " DASH_PASS
DASH_PASS=${DASH_PASS:-$(generate_password)}

DASH_AUTH=$(htpasswd -nbB $DASH_USER $DASH_PASS | cut -d ":" -f 2)

# --- CHECK PORTS ---
check_port_53

# --- INSTALL DOCKER + COMPOSE ---
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

# --- CREATE .env ---
cat > .env <<EOF
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
echo ".env file created."

# --- DOWNLOAD COMPOSE FILE ---
curl -fsSL https://raw.githubusercontent.com/DNSSEC-Manager/DNSSEC-Manager/main/compose.prod-traefik.yml -o compose.prod-traefik.yml
echo "compose.prod-traefik.yml downloaded."

# --- FIREWALL ---
if command -v ufw >/dev/null; then
  echo "Configuring firewall..."
  ufw allow 53/tcp
  ufw allow 53/udp
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

# --- START STACK ---
echo "Starting Docker stack..."
docker compose -f compose.prod-traefik.yml up -d

# --- SYSTEMD SERVICE ---
SERVICE_FILE="/etc/systemd/system/dnssecmanager.service"
cat > $SERVICE_FILE <<EOF
[Unit]
Description=DNSSEC-Manager Stack
After=docker.service
Requires=docker.service

[Service]
WorkingDirectory=$(pwd)
ExecStart=/usr/local/bin/docker compose -f $(pwd)/compose.prod-traefik.yml up
ExecStop=/usr/local/bin/docker compose -f $(pwd)/compose.prod-traefik.yml down
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dnssecmanager
systemctl start dnssecmanager

# --- HEALTHCHECKS ---
echo "Waiting for PowerDNS API..."
wait_for_url "http://localhost:8081" "PowerDNS API"

echo "Waiting for Backend UI..."
wait_for_url "http://localhost:8080" "Backend"

echo "Waiting for Traefik HTTPS certificates..."
retries=60
until curl -kfsS "https://$DOMAIN" >/dev/null 2>&1 || [[ $retries -le 0 ]]; do
  echo -n "."
  sleep 5
  ((retries--))
done
if [[ $retries -le 0 ]]; then
  echo ""
  echo "ERROR: HTTPS not ready for $DOMAIN"
  exit 1
fi
echo "Traefik HTTPS is up!"

# --- DONE ---
echo ""
echo "✅ Installation complete!"
echo "Backend: https://$DOMAIN"
echo "Dashboard: https://$DOMAIN_DASHBOARD (user: $DASH_USER, pass: $DASH_PASS)"
echo "PDNS API Key: $PDNS_API_KEY"
echo "DB passwords stored in .env"
echo "Full log available at $LOG_FILE"
