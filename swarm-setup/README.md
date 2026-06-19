
# Atlas Docker Swarm Lab

A single-script setup that provisions a full Docker Swarm cluster inside LXC containers on an Ubuntu VM, then deploys the Atlas application stack automatically.

---

## What This Does

Running one script on your Ubuntu VM builds this entire environment from scratch:

```
Ubuntu VM (VMware)
└── LXC Environment
    ├── swarm-manager   (Ubuntu 22.04) — Swarm leader, stack deploy
    ├── swarm-worker1   (Ubuntu 22.04) — Runs api-service + frontend-service
    ├── swarm-worker2   (Ubuntu 22.04) — Runs admin-service + nginx-gateway
    └── swarm-worker3   (Alpine 3.21)  — Drained (cgroup incompatibility)
```

Traffic flow:

```
Browser → VM IP :80 → nginx-gateway → frontend-service  (:3000)
                                     → api-service       (:5000)
                                     → admin-service     (:6000)
```

---

## Prerequisites

### VMware Network Setting (do this before anything else)

In VMware → VM Settings → Network Adapter:
- Set to **Bridged**
- Bridged to: **Automatic** (or your physical NIC)

This gives your VM its own IP on your local network so you can open the app from your host browser.

### Ubuntu VM Requirements

- Ubuntu 22.04 or 24.04
- `sudo` access
- Internet access (to pull LXC images and Docker Hub images)
- Ports open: `80/tcp`, `2377/tcp`, `7946/tcp+udp`, `4789/udp`

---

## Quick Start

```bash
# 1. Clone or copy swarm-setup.sh to your Ubuntu VM

# 2. Make it executable
chmod +x swarm-setup.sh

# 3. Run it (takes 5–10 minutes on first run)
sudo bash swarm-setup.sh
```

That's it. The script handles everything.

---

## Configuration

At the top of `swarm-setup.sh` is a small config block — the only part you may need to edit:

```bash
# Network bridge (default is fine for most setups)
LXC_BRIDGE="lxcbr0"

# IPs for each node — must match your lxcbr0 subnet
# Check with: ip addr show lxcbr0
MANAGER_IP="10.0.3.10"
WORKER1_IP="10.0.3.11"
WORKER2_IP="10.0.3.12"
WORKER3_IP="10.0.3.13"

# Docker Hub image tags
IMG_FRONTEND="varenya0129/atlas-frontend-service:1.0"
IMG_API="varenya0129/atlas-api-service:1.0"
IMG_ADMIN="varenya0129/atlas-admin-service:1.0"
IMG_NGINX="varenya0129/atlas-nginx-gateway:1.0"
```

**Before running**, verify your LXC bridge subnet:
```bash
ip addr show lxcbr0
# If it shows 10.0.3.1 — no changes needed
# If it shows something else — update the four IPs above to match
```

---

## What the Script Does (Step by Step)

| Step | What happens |
|---|---|
| Pre-flight | Installs LXC if missing, verifies tools |
| Section 1 | Creates 3 Ubuntu + 1 Alpine LXC containers with static IPs |
| Section 2 | Fixes container configs, starts all 4 containers |
| Section 3 | Installs Docker Engine inside each Ubuntu container |
| Section 4 | Installs Docker inside the Alpine container |
| Section 5 | Opens swarm ports (2377, 7946, 4789) on all nodes |
| Section 6 | Runs `docker swarm init` on the manager |
| Section 7 | Joins all 3 workers to the swarm |
| Section 8 | Writes `stack.yml` with your image tags directly into the manager |
| Section 9 | Pulls all images on all workers (so deploy is instant) |
| Section 10 | Deploys the stack with `docker stack deploy` |
| Final | Prints swarm node list, service status, and app URL |

---

## Accessing the App

After the script completes:

```bash
# Find your VM's IP
ip addr show ens33 | grep "inet "
```

Open your browser on your host machine and go to:
```
http://<your-vm-ip>
```

To test from inside the VM:
```bash
sudo lxc-attach -n swarm-worker1 -- curl -I http://localhost:80
# Should return: HTTP/1.1 200 OK
```

---

## Day-to-Day Commands

All swarm commands run via `lxc-attach` from the Ubuntu VM:

```bash
# Watch live service status
sudo lxc-attach -n swarm-manager -- docker stack ps atlas

# List services and replica counts
sudo lxc-attach -n swarm-manager -- docker stack services atlas

# View logs for a service
sudo lxc-attach -n swarm-worker1 -- docker service logs atlas_api-service

# Scale a service up
sudo lxc-attach -n swarm-manager -- docker service scale atlas_api-service=2

# Update a service to a new image version
sudo lxc-attach -n swarm-manager -- \
  docker service update --image varenya0129/atlas-api-service:1.1 atlas_api-service

# Check swarm node health
sudo lxc-attach -n swarm-manager -- docker node ls
```

---

## Updating Image Versions

1. Edit the config block at the top of `swarm-setup.sh`:
   ```bash
   IMG_API="varenya0129/atlas-api-service:1.1"
   ```

2. Re-run the script — it detects the existing swarm, removes the old stack, and redeploys with the new tags:
   ```bash
   sudo bash swarm-setup.sh
   ```

Or update a single service live without re-running the script:
```bash
sudo lxc-attach -n swarm-manager -- \
  docker service update --image varenya0129/atlas-api-service:1.1 atlas_api-service
```

---

## Tearing Down

```bash
# Remove just the app stack (keeps swarm intact)
sudo lxc-attach -n swarm-manager -- docker stack rm atlas

# Stop all LXC containers
sudo lxc-stop -n swarm-manager
sudo lxc-stop -n swarm-worker1
sudo lxc-stop -n swarm-worker2
sudo lxc-stop -n swarm-worker3

# Destroy everything (permanent — deletes all containers)
sudo lxc-destroy -n swarm-manager -f
sudo lxc-destroy -n swarm-worker1 -f
sudo lxc-destroy -n swarm-worker2 -f
sudo lxc-destroy -n swarm-worker3 -f
```

After destroying, you can run `sudo bash swarm-setup.sh` again for a completely fresh setup.

---

## Troubleshooting

### `lxc-attach: You lack access to ...`
You forgot `sudo`. Always prefix lxc commands with `sudo`:
```bash
sudo lxc-attach -n swarm-manager -- docker node ls
```

### Container won't start
Check the actual error:
```bash
sudo lxc-start -n swarm-manager --logfile=/tmp/lxc.log --logpriority=DEBUG
sudo cat /tmp/lxc.log | tail -30
```

### Service stuck at `0/1` replicas
Check why containers are failing:
```bash
sudo lxc-attach -n swarm-manager -- docker stack ps atlas --no-trunc
```
The `ERROR` column shows the exact failure reason.

### Image pull failing on workers
Verify the tag exists and is public:
```bash
sudo lxc-attach -n swarm-worker1 -- docker pull varenya0129/atlas-api-service:1.0
```

### Alpine worker (swarm-worker3) container failures
Known issue — Alpine 3.21 in LXC has incomplete cgroup v2 support for Docker.
The swarm automatically avoids it. Keep it drained:
```bash
sudo lxc-attach -n swarm-manager -- docker node update --availability drain swarm-worker3
```

### Check lxcbr0 subnet
```bash
ip addr show lxcbr0
# Should show something like: inet 10.0.3.1/24
# If different, update the IP config block in swarm-setup.sh
```

---

## Project Structure

```
.
├── swarm-setup.sh    # The full setup script — run this
└── README.md         # This file
```

---

## Notes on Security

- LXC containers run with `apparmor unconfined` and `cap.drop =` cleared — required for Docker-in-LXC. This is appropriate for a local lab environment, not for production.
- No secrets or credentials are stored in this script. All images are public on Docker Hub.
- The swarm overlay network (`backend-net`) is marked `internal: true` — the api-service and admin-service cannot make outbound internet requests directly, only nginx-gateway can reach them.

---

## Architecture Reference

```
┌─────────────────────────────────────────────────┐
│                   INTERNET                      │
│              (Client Requests :80)              │
└────────────────────┬────────────────────────────┘
                     │
        ┌────────────▼──────────────┐
        │      nginx-gateway        │
        │      (Reverse Proxy)      │
        │      Port 80              │
        └──────┬──────────┬─────────┘
               │          │
    ┌──────────▼─┐    ┌───▼──────────────────┐
    │  frontend  │    │   backend-net         │
    │  :3000     │    │   (overlay, internal) │
    └────────────┘    │   api-service  :5000  │
                      │   admin-service :6000 │
                      └──────────────────────┘
```
