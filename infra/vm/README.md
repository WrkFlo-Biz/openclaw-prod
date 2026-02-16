# OpenClaw VM Hosting (Azure)

This directory contains the VM-first production topology for OpenClaw.

## Architecture

- One Ubuntu LTS VM runs the OpenClaw gateway as a Docker container.
- Live state is stored on an attached Premium SSD (`/data/openclaw/.openclaw`).
- Gateway binds to loopback and is published via Tailscale Serve (or SSH tunnel fallback).
- Local computer access is provided by running `openclaw node` on your workstation.

## Files

- `bootstrap-vm.sh`: Installs Docker/Azure CLI/Tailscale and mounts the Premium SSD.
- `openclaw-gateway.service`: systemd unit for the gateway container.
- `openclaw-state-archive.sh`: Periodic state archive upload to Azure Blob.
- `openclaw-state-archive.service` + `openclaw-state-archive.timer`: systemd units for daily archives.

## Deployment Notes

1. Provision VM + managed identity + Premium SSD.
2. Run `bootstrap-vm.sh` as root.
   - Default state ownership is `uid/gid 997` (OpenClaw container user).
3. Sync existing state into `/data/openclaw/.openclaw`.
4. Place env vars into `/etc/openclaw/openclaw.env`.
   - For Docker hosting, set `OPENCLAW_GATEWAY_BIND=lan` so the process listens inside the container.
   - Set `OPENCLAW_IMAGE=<acr>.azurecr.io/openclaw:<tag>` for rollout control.
   - Keep host exposure private with `-p 127.0.0.1:18789:18789` in the systemd unit.
5. Install and start `openclaw-gateway.service`.
6. Enable archive timer and configure Tailscale.
7. Cut over by stopping legacy ACA/OpenClaw instances to avoid Telegram `getUpdates` conflicts.

## Local Node Access

- Install SSH tunnel fallback (macOS LaunchAgent):
  - Copy `ai.openclaw.vm-tunnel.plist.example` to `~/Library/LaunchAgents/ai.openclaw.vm-tunnel.plist`.
  - Replace `REPLACE_ME` + `REPLACE_VM_IP`.
  - Load with `launchctl load -w ~/Library/LaunchAgents/ai.openclaw.vm-tunnel.plist`.
- Point local CLI to the tunnel:
  - `gateway.remote.url = ws://127.0.0.1:18789`
  - `gateway.remote.token = <OPENCLAW_GATEWAY_TOKEN>`
- Install local node host service:
  - `openclaw node install --host 127.0.0.1 --port 18789 --display-name "<your-machine>" --force`
  - `openclaw node restart`
  - If node logs show `EPROTO` on localhost, remove `--tls` from `~/Library/LaunchAgents/ai.openclaw.node.plist` and restart the LaunchAgent.
