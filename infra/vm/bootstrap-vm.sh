#!/usr/bin/env bash
set -euo pipefail

# Idempotent VM bootstrap for OpenClaw gateway hosting.
DISK_DEV="${DISK_DEV:-/dev/disk/azure/scsi1/lun0}"
DATA_ROOT="${DATA_ROOT:-/data/openclaw}"
OPENCLAW_UID="${OPENCLAW_UID:-997}"
OPENCLAW_GID="${OPENCLAW_GID:-997}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release jq rsync unzip apt-transport-https software-properties-common

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

usermod -aG docker openclaw || true

if ! command -v az >/dev/null 2>&1; then
  curl -sL https://aka.ms/InstallAzureCLIDeb | bash
fi

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if [ ! -b "$DISK_DEV" ]; then
  echo "Data disk device not found: $DISK_DEV" >&2
  exit 1
fi

if ! blkid "$DISK_DEV" >/dev/null 2>&1; then
  mkfs.ext4 -F "$DISK_DEV"
fi

mkdir -p "$DATA_ROOT"
if ! grep -q "$DISK_DEV $DATA_ROOT " /etc/fstab; then
  echo "$DISK_DEV $DATA_ROOT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

mountpoint -q "$DATA_ROOT" || mount "$DATA_ROOT"
mkdir -p "$DATA_ROOT/.openclaw" /etc/openclaw /opt/openclaw-vm /var/log/openclaw
# OpenClaw container runs as uid/gid 997 by default. Keep mounted state writable.
chown -R "${OPENCLAW_UID}:${OPENCLAW_GID}" "$DATA_ROOT" /opt/openclaw-vm /var/log/openclaw

echo "Bootstrap complete."
