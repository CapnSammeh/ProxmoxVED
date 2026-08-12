#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Sam Herring (CapnSammeh)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/block/buzz

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y curl git build-essential pkg-config libssl-dev libpq-dev redis-server
msg_ok "Installed Dependencies"

msg_info "Setting up PostgreSQL"
PG_VERSION="17" setup_postgresql
PG_DB_NAME="buzz" PG_DB_USER="buzz" setup_postgresql_db
msg_ok "Set up PostgreSQL"

msg_info "Setting up MinIO"
# dl.min.io has no IPv6 records; force IPv4 (container may have broken IPv6 state)
if ! $STD curl -4 -fsSL "https://dl.min.io/server/minio/release/linux-amd64/minio" -o /usr/local/bin/minio; then
  msg_warn "dl.min.io failed, retrying"
  $STD curl -4 -fsSL --retry 3 --retry-delay 2 "https://dl.min.io/server/minio/release/linux-amd64/minio" -o /usr/local/bin/minio
fi
chmod +x /usr/local/bin/minio
mkdir -p /opt/minio/data
cat <<EOF >/etc/systemd/system/minio.service
[Unit]
Description=MinIO Object Storage
After=network.target

[Service]
ExecStart=/usr/local/bin/minio server /opt/minio/data --address ":9000" --console-address ":9001"
EnvironmentFile=/etc/default/minio
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Set up MinIO service (creds configured after secret generation)"

msg_info "Setting up Rust"
setup_rust
msg_ok "Set up Rust"

msg_info "Cloning Buzz"
git clone --depth 1 https://github.com/block/buzz.git /opt/buzz
cd /opt/buzz
msg_ok "Cloned Buzz"

msg_info "Building Buzz Relay (this can take 10-20 minutes)"
$STD cargo build --release -p buzz-relay
msg_ok "Built Buzz Relay"

msg_info "Configuring Buzz"
BUZZ_RELAY_KEY=$(openssl rand -hex 32)
BUZZ_HMAC_KEY=$(openssl rand -hex 32)
POSTGRES_PW="$PG_DB_PASS"
REDIS_PW=$(openssl rand -hex 16)
MINIO_AK=$(openssl rand -hex 16)
MINIO_SK=$(openssl rand -hex 32)

cat <<EOF >/opt/buzz/buzz.env
BUZZ_BIND_ADDR=0.0.0.0:3000
BUZZ_HEALTH_PORT=8080
DATABASE_URL=postgres://buzz:${POSTGRES_PW}@127.0.0.1:5432/buzz
REDIS_URL=redis://:${REDIS_PW}@127.0.0.1:6379
BUZZ_S3_ENDPOINT=http://127.0.0.1:9000
BUZZ_S3_ADDRESSING_STYLE=path
BUZZ_S3_ACCESS_KEY=${MINIO_AK}
BUZZ_S3_SECRET_KEY=${MINIO_SK}
BUZZ_S3_BUCKET=buzz-media
BUZZ_GIT_REPO_PATH=/opt/buzz/git-data
BUZZ_AUTO_MIGRATE=true
BUZZ_RELAY_PRIVATE_KEY=${BUZZ_RELAY_KEY}
BUZZ_GIT_HOOK_HMAC_SECRET=${BUZZ_HMAC_KEY}
RELAY_URL=http://${LOCAL_IP}:3000
BUZZ_MEDIA_BASE_URL=http://${LOCAL_IP}:3000/media
BUZZ_CORS_ORIGINS=http://${LOCAL_IP}:3000
RUST_LOG=buzz_relay=info
EOF

# Write MinIO creds with the generated secrets, then start it
cat <<EOF >/etc/default/minio
MINIO_ROOT_USER=${MINIO_AK}
MINIO_ROOT_PASSWORD=${MINIO_SK}
MINIO_VOLUMES=/opt/minio/data
MINIO_OPTS="--address :9000 --console-address :9001"
EOF
systemctl enable -q --now minio

# Wait for MinIO to be ready, then create the buzz-media bucket (required by relay A3 gate)
for i in $(seq 1 15); do
  curl -fsS "http://127.0.0.1:9000/minio/health/live" >/dev/null 2>&1 && break
  sleep 1
done
$STD curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc
$STD mc alias set buzzlocal "http://127.0.0.1:9000" "${MINIO_AK}" "${MINIO_SK}"
$STD mc mb buzzlocal/buzz-media
msg_ok "Created MinIO bucket buzz-media"

# Set Redis password (Redis is started as dependency service)
if grep -q "^# requirepass" /etc/redis/redis.conf; then
  sed -i "s|^# requirepass.*|requirepass ${REDIS_PW}|" /etc/redis/redis.conf
else
  echo "requirepass ${REDIS_PW}" >> /etc/redis/redis.conf
fi
systemctl restart redis-server
msg_ok "Configured Buzz"

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/buzz-relay.service
[Unit]
Description=Buzz Relay
After=network-online.target postgresql.service redis-server.service minio.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/buzz
EnvironmentFile=/opt/buzz/buzz.env
ExecStart=/opt/buzz/target/release/buzz-relay
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now buzz-relay
msg_ok "Created Services"

motd_ssh
customize
cleanup_lxc
