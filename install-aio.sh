#!/bin/bash
#
# install-aio.sh
# Bootstraps a fresh Ubuntu 24.04 ARM64 VM for Nextcloud All-in-One (AIO).
#  - Mounts the 128 GB data disk at /mnt/ncdata
#  - Installs Docker engine
#  - Starts the AIO mastercontainer (which then installs Nextcloud 33 + friends)
#
# Usage:
#   sudo bash install-aio.sh --fqdn=cloud.example.com --email=you@example.com
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
FQDN=""
EMAIL=""
DATA_MOUNT="/mnt/ncdata"

for arg in "$@"; do
  case "$arg" in
    --fqdn=*)  FQDN="${arg#*=}" ;;
    --email=*) EMAIL="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" ;;
  esac
done

if [[ -z "$FQDN" || -z "$EMAIL" ]]; then
  echo "ERROR: --fqdn and --email are required" >&2
  exit 2
fi

echo "==> Installing for FQDN=$FQDN, email=$EMAIL"

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------
apt-get update
apt-get -y upgrade
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  parted xfsprogs jq ufw unattended-upgrades

# -----------------------------------------------------------------------------
# Format and mount the data disk (lun 0 -> usually /dev/sdc on Azure ARM VMs)
# Use by-id symlink for robustness across reboots.
# -----------------------------------------------------------------------------
echo "==> Locating data disk..."
DATA_DISK=""
for candidate in /dev/disk/azure/scsi1/lun0 /dev/sdc /dev/sdb; do
  if [[ -e "$candidate" ]]; then
    DATA_DISK="$(readlink -f "$candidate")"
    break
  fi
done

if [[ -z "$DATA_DISK" ]]; then
  echo "ERROR: could not find data disk" >&2
  lsblk
  exit 3
fi

echo "==> Using data disk: $DATA_DISK"

if ! blkid "${DATA_DISK}1" >/dev/null 2>&1; then
  echo "==> Partitioning and formatting $DATA_DISK as XFS"
  parted -s "$DATA_DISK" mklabel gpt mkpart primary xfs 0% 100%
  sleep 2
  mkfs.xfs -f "${DATA_DISK}1"
fi

mkdir -p "$DATA_MOUNT"
UUID="$(blkid -s UUID -o value "${DATA_DISK}1")"
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID  $DATA_MOUNT  xfs  defaults,nofail,discard  0 2" >> /etc/fstab
fi
mount -a
chown -R root:root "$DATA_MOUNT"
chmod 770 "$DATA_MOUNT"

# AIO needs its own subdirectory it can fully own
mkdir -p "$DATA_MOUNT/nextcloud_data"

# -----------------------------------------------------------------------------
# Docker engine (official repo, arm64)
# -----------------------------------------------------------------------------
echo "==> Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Allow the admin user to run docker without sudo (optional, convenient)
ADMIN_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
if [[ -n "$ADMIN_USER" ]]; then
  usermod -aG docker "$ADMIN_USER" || true
fi

# -----------------------------------------------------------------------------
# Firewall (defense-in-depth; Azure NSG also enforces this)
# -----------------------------------------------------------------------------
echo "==> Configuring ufw"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 8080/tcp comment 'AIO admin'
ufw allow 3478/tcp comment 'Talk STUN/TURN'
ufw allow 3478/udp comment 'Talk STUN/TURN'
ufw --force enable

# -----------------------------------------------------------------------------
# Start the Nextcloud AIO mastercontainer
# Docs: https://github.com/nextcloud/all-in-one
# -----------------------------------------------------------------------------
echo "==> Starting Nextcloud AIO mastercontainer"
docker run -d \
  --name nextcloud-aio-mastercontainer \
  --restart always \
  --init \
  --sig-proxy=false \
  --publish 80:80 \
  --publish 8080:8080 \
  --publish 8443:8443 \
  --volume nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
  --volume /var/run/docker.sock:/var/run/docker.sock:ro \
  -e NEXTCLOUD_DATADIR="$DATA_MOUNT/nextcloud_data" \
  -e NEXTCLOUD_MOUNT="$DATA_MOUNT" \
  -e APACHE_PORT=443 \
  -e APACHE_IP_BINDING=0.0.0.0 \
  -e NEXTCLOUD_UPLOAD_LIMIT=16G \
  -e NEXTCLOUD_MAX_TIME=7200 \
  ghcr.io/nextcloud-releases/all-in-one:latest

# -----------------------------------------------------------------------------
# Enable unattended security updates for Ubuntu
# -----------------------------------------------------------------------------
dpkg-reconfigure -f noninteractive unattended-upgrades

cat <<EOF

==============================================================================
  Nextcloud AIO bootstrap complete.

  1. Open the AIO admin UI in your browser:
       https://${FQDN}:8080
     (You'll see a TLS warning — AIO uses a self-signed cert on 8080.
      Accept it; this URL is for admin-only configuration.)

  2. Save the master password shown on the first screen.

  3. In the AIO dashboard:
       - Submit your domain: ${FQDN}
       - Email for Let's Encrypt: ${EMAIL}
       - Pick the optional containers you want
         (Recommended: Collabora, Talk, Imaginary, ClamAV, Fulltextsearch, Whiteboard)
       - Click "Download and start containers"

  4. After 5-10 minutes, your Nextcloud will be live at:
       https://${FQDN}

  See Nextcloud_AIO_Setup.md for next steps:
   - Adding Azure Blob as External Storage for photos
   - iPhone Auto Upload configuration
   - Migrating data from your old v31 instance
==============================================================================
EOF
