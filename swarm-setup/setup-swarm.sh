#!/usr/bin/env bash
# =============================================================================
#  Atlas Docker Swarm Lab — Full Setup Script
#  Run this ONCE on your Ubuntu VM as root (or with sudo)
#  It will: install LXC, create 4 containers (1 manager + 3 workers),
#  install Docker in each, form the swarm, and deploy your stack.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION — edit these before running
# ─────────────────────────────────────────────────────────────────────────────

# Bridge network your LXC containers will use (must exist on the host)
# Usually lxcbr0 is auto-created by LXC. If you use a custom bridge, change it.
LXC_BRIDGE="lxcbr0"

# IP addresses for each node — must be on the same subnet as LXC_BRIDGE
# Default lxcbr0 subnet is 10.0.3.0/24 — adjust if yours is different
MANAGER_IP="10.0.3.10"
WORKER1_IP="10.0.3.11"   # Ubuntu worker
WORKER2_IP="10.0.3.12"   # Ubuntu worker
WORKER3_IP="10.0.3.13"   # Alpine worker

# Docker Hub images
IMG_FRONTEND="varenya0129/atlas-frontend-service:1.0"
IMG_API="varenya0129/atlas-api-service:1.0"
IMG_ADMIN="varenya0129/atlas-admin-service:1.0"
IMG_NGINX="varenya0129/atlas-nginx-gateway:1.0"

# LXC container names
MGR="swarm-manager"
W1="swarm-worker1"
W2="swarm-worker2"
W3="swarm-worker3"

# ─────────────────────────────────────────────────────────────────────────────
#  COLOURS & HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# Run a shell command inside an LXC container
lxc_exec() {
  local container=$1; shift
  lxc-attach -n "$container" -- bash -c "$*"
}

# Run a shell command inside the Alpine LXC container (uses sh not bash)
lxc_exec_sh() {
  local container=$1; shift
  lxc-attach -n "$container" -- sh -c "$*"
}

wait_for_container() {
  local name=$1
  info "Waiting for $name to be running..."
  for i in $(seq 1 40); do
    STATE=$(lxc-info -n "$name" 2>/dev/null | grep "^State:" | awk '{print $NF}')
    if [[ "$STATE" == "RUNNING" ]]; then
      success "$name is up"
      return 0
    fi
    sleep 3
  done
  error "$name did not reach RUNNING state within 120 seconds"
}

wait_for_network() {
  local name=$1 ip=$2
  info "Waiting for network in $name ($ip)..."
  for i in $(seq 1 30); do
    if lxc-attach -n "$name" -- ping -c1 -W1 8.8.8.8 &>/dev/null; then
      success "$name has internet access"
      return 0
    fi
    sleep 2
  done
  warn "$name may not have internet — continuing anyway"
}

# ─────────────────────────────────────────────────────────────────────────────
#  PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
section "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash swarm-setup.sh"

for cmd in lxc-create lxc-start lxc-attach lxc-info lxc-stop lxc-destroy; do
  if ! command -v "$cmd" &>/dev/null; then
    info "LXC not found — installing..."
    apt-get update -qq
    apt-get install -y -qq lxc lxc-templates uidmap
    break
  fi
done
success "LXC classic tools available"

# Guard: Ubuntu ships 'lxc' as an alias to LXD snap — completely separate from
# the lxc-* classic tools this script uses. They do NOT conflict; we just clarify.
if command -v lxc &>/dev/null && command -v lxc | grep -q snap 2>/dev/null; then
  warn "'lxc' command points to LXD snap — this script only uses lxc-create/lxc-start/lxc-attach etc. (classic). No conflict."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — Create LXC containers
# ─────────────────────────────────────────────────────────────────────────────
section "Creating LXC containers"

# Clean up any containers left in a broken state from a previous failed run
for c in "$MGR" "$W1" "$W2" "$W3"; do
  if lxc-info -n "$c" &>/dev/null; then
    STATE=$(lxc-info -n "$c" | grep "^State:" | awk '{print $NF}')
    if [[ "$STATE" != "RUNNING" ]]; then
      # Container exists but isn't running — check if rootfs is usable
      if [[ ! -f /var/lib/lxc/$c/config ]]; then
        warn "$c exists but has no config — destroying and recreating"
        lxc-destroy -n "$c" -f 2>/dev/null || true
      fi
    fi
  fi
done

create_ubuntu_container() {
  local name=$1 ip=$2
  if lxc-info -n "$name" &>/dev/null; then
    warn "$name already exists — skipping creation"
  else
    info "Creating Ubuntu 22.04 container: $name"
    lxc-create -n "$name" -t download -- \
      --dist ubuntu --release jammy --arch amd64
    success "Created $name"
  fi

  # Ensure config.d exists (not always created by lxc-create)
  mkdir -p /var/lib/lxc/$name/config.d

  # The lxc-download template already writes lxc.net.0.type/link/flags.
  # We ONLY append the static IP lines if not already present.
  # Also fix the apparmor line: replace "generated" with "unconfined" for Docker nesting.
  sed -i 's/^lxc.apparmor.profile = generated/lxc.apparmor.profile = unconfined/' /var/lib/lxc/$name/config
  sed -i 's/^lxc.apparmor.allow_nesting = 1/lxc.apparmor.allow_nesting = 1\nlxc.cap.drop =\nlxc.mount.auto = proc:rw sys:rw cgroup:rw/' /var/lib/lxc/$name/config

  # Add static IP only (net type/link/flags already set by template)
  grep -q "lxc.net.0.ipv4.address" /var/lib/lxc/$name/config || cat >> /var/lib/lxc/$name/config <<EOF
lxc.net.0.ipv4.address = ${ip}/24
lxc.net.0.ipv4.gateway = auto
EOF

  success "Configured $name (IP: $ip)"
}

create_alpine_container() {
  local name=$1 ip=$2
  if lxc-info -n "$name" &>/dev/null; then
    warn "$name already exists — skipping creation"
  else
    info "Creating Alpine 3.21 container: $name"
    lxc-create -n "$name" -t download -- \
      --dist alpine --release 3.21 --arch amd64
    success "Created $name"
  fi

  # Ensure config.d exists
  mkdir -p /var/lib/lxc/$name/config.d

  # Same as Ubuntu: only add ipv4 lines, fix apparmor for Docker nesting
  sed -i 's/^lxc.apparmor.profile = generated/lxc.apparmor.profile = unconfined/' /var/lib/lxc/$name/config
  grep -q "lxc.cap.drop" /var/lib/lxc/$name/config || echo "lxc.cap.drop =" >> /var/lib/lxc/$name/config
  grep -q "lxc.mount.auto" /var/lib/lxc/$name/config || echo "lxc.mount.auto = proc:rw sys:rw cgroup:rw" >> /var/lib/lxc/$name/config

  # Add static IP only
  grep -q "lxc.net.0.ipv4.address" /var/lib/lxc/$name/config || cat >> /var/lib/lxc/$name/config <<EOF
lxc.net.0.ipv4.address = ${ip}/24
lxc.net.0.ipv4.gateway = auto
EOF

  success "Configured $name (IP: $ip)"
}

create_ubuntu_container "$MGR"  "$MANAGER_IP"
create_ubuntu_container "$W1"   "$WORKER1_IP"
create_ubuntu_container "$W2"   "$WORKER2_IP"
create_alpine_container "$W3"   "$WORKER3_IP"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — Start containers
# ─────────────────────────────────────────────────────────────────────────────
section "Starting LXC containers"

# Fix configs on already-existing containers (deduplicate net lines, fix apparmor)
for c in "$MGR" "$W1" "$W2" "$W3"; do
  CFG="/var/lib/lxc/$c/config"
  if [[ -f "$CFG" ]]; then
    # Remove duplicate lxc.net.0.type / lxc.net.0.link / lxc.net.0.flags lines (keep first)
    awk '!seen[$0]++' "$CFG" > /tmp/lxc_cfg_dedup && mv /tmp/lxc_cfg_dedup "$CFG"
    # Replace generated apparmor profile with unconfined for Docker nesting
    sed -i 's/^lxc.apparmor.profile = generated/lxc.apparmor.profile = unconfined/' "$CFG"
    # Ensure cap.drop is cleared (required for Docker)
    grep -q "^lxc.cap.drop =" "$CFG" || echo "lxc.cap.drop =" >> "$CFG"
    # Ensure cgroup mount is rw
    grep -q "lxc.mount.auto" "$CFG" || echo "lxc.mount.auto = proc:rw sys:rw cgroup:rw" >> "$CFG"
    info "Config verified for $c"
  fi
done

for c in "$MGR" "$W1" "$W2" "$W3"; do
  # Parse state directly from lxc-info — handle multiple spaces in output
  STATE=$(lxc-info -n "$c" 2>/dev/null | grep "^State:" | awk '{print $NF}')
  info "$c state: '${STATE}'"
  if [[ "$STATE" == "RUNNING" ]]; then
    success "$c already running"
  else
    info "Starting $c..."
    lxc-start -n "$c" 2>/dev/null || true
    sleep 3
    wait_for_container "$c"
  fi
done

sleep 5  # Let network settle

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — Install Docker in Ubuntu containers
# ─────────────────────────────────────────────────────────────────────────────
section "Installing Docker in Ubuntu containers"

install_docker_ubuntu() {
  local name=$1
  info "Installing Docker in $name..."
  lxc_exec "$name" "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  "
  success "Docker installed in $name"
}

install_docker_ubuntu "$MGR"
install_docker_ubuntu "$W1"
install_docker_ubuntu "$W2"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — Install Docker in Alpine container
# ─────────────────────────────────────────────────────────────────────────────
section "Installing Docker in Alpine worker (Worker 3)"

lxc_exec_sh "$W3" "
  apk update
  apk add --no-cache docker docker-cli openrc
  rc-update add docker default
  service docker start || true
"
success "Docker installed in $W3"

# Give Docker daemons a moment to be ready
sleep 8

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — Open swarm firewall ports on all nodes
# ─────────────────────────────────────────────────────────────────────────────
section "Configuring firewall ports for Docker Swarm"

open_ports_ubuntu() {
  local name=$1
  lxc_exec "$name" "
    ufw allow 2377/tcp  2>/dev/null || true
    ufw allow 7946/tcp  2>/dev/null || true
    ufw allow 7946/udp  2>/dev/null || true
    ufw allow 4789/udp  2>/dev/null || true
    ufw allow 80/tcp    2>/dev/null || true
    iptables -I INPUT -p tcp --dport 2377 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 7946 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport 7946 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport 4789 -j ACCEPT 2>/dev/null || true
  " 2>/dev/null || true
}

open_ports_ubuntu "$MGR"
open_ports_ubuntu "$W1"
open_ports_ubuntu "$W2"

lxc_exec_sh "$W3" "
  iptables -I INPUT -p tcp --dport 2377 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p tcp --dport 7946 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p udp --dport 7946 -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p udp --dport 4789 -j ACCEPT 2>/dev/null || true
" 2>/dev/null || true

success "Firewall ports opened on all nodes"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 6 — Initialize Docker Swarm on manager
# ─────────────────────────────────────────────────────────────────────────────
section "Initializing Docker Swarm on manager"

SWARM_ALREADY=$(lxc_exec "$MGR" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null" || echo "inactive")

if [[ "$SWARM_ALREADY" == "active" ]]; then
  warn "Swarm already active on $MGR"
else
  lxc_exec "$MGR" "docker swarm init --advertise-addr ${MANAGER_IP}"
  success "Swarm initialized on $MGR ($MANAGER_IP)"
fi

# Extract worker join token
JOIN_TOKEN=$(lxc_exec "$MGR" "docker swarm join-token -q worker")
info "Worker join token acquired"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 7 — Join workers to the swarm
# ─────────────────────────────────────────────────────────────────────────────
section "Joining worker nodes to the swarm"

join_worker_ubuntu() {
  local name=$1
  local already=$(lxc_exec "$name" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null" || echo "inactive")
  if [[ "$already" == "active" ]]; then
    warn "$name already in swarm"
  else
    lxc_exec "$name" "docker swarm join --token ${JOIN_TOKEN} ${MANAGER_IP}:2377"
    success "$name joined the swarm"
  fi
}

join_worker_sh() {
  local name=$1
  local already=$(lxc_exec_sh "$name" "docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null" || echo "inactive")
  if [[ "$already" == "active" ]]; then
    warn "$name already in swarm"
  else
    lxc_exec_sh "$name" "docker swarm join --token ${JOIN_TOKEN} ${MANAGER_IP}:2377"
    success "$name joined the swarm"
  fi
}

join_worker_ubuntu "$W1"
join_worker_ubuntu "$W2"
join_worker_sh     "$W3"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 8 — Write the Docker Stack compose file on the manager
# ─────────────────────────────────────────────────────────────────────────────
section "Writing Docker Stack file on manager"

lxc_exec "$MGR" "mkdir -p /opt/atlas"

# Write stack.yml directly on the HOST, then copy into the manager container
# This avoids shell variable expansion issues inside lxc_exec heredocs
STACK_FILE="/var/lib/lxc/${MGR}/rootfs/opt/atlas/stack.yml"
mkdir -p "$(dirname $STACK_FILE)"

cat > "$STACK_FILE" <<STACKEOF
version: '3.8'

networks:
  frontend-net:
    driver: overlay
    attachable: true
  backend-net:
    driver: overlay
    attachable: true
    internal: true

services:

  frontend-service:
    image: ${IMG_FRONTEND}
    networks:
      - frontend-net
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      restart_policy:
        condition: on-failure
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    cap_drop:
      - NET_RAW

  api-service:
    image: ${IMG_API}
    networks:
      - backend-net
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      restart_policy:
        condition: on-failure
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    cap_drop:
      - NET_RAW
      - NET_ADMIN

  admin-service:
    image: ${IMG_ADMIN}
    networks:
      - backend-net
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      restart_policy:
        condition: on-failure
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
    cap_drop:
      - NET_RAW
      - NET_ADMIN

  nginx-gateway:
    image: ${IMG_NGINX}
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: ingress
    networks:
      - frontend-net
      - backend-net
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == worker
      restart_policy:
        condition: on-failure
      resources:
        limits:
          cpus: '0.5'
          memory: 128M
    cap_drop:
      - NET_RAW

STACKEOF

info "Stack file written — verifying image tags inside file..."
grep "image:" "$STACK_FILE"
success "Stack file written to /opt/atlas/stack.yml on $MGR"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 9 — Pull images on all workers (speeds up first deploy)
# ─────────────────────────────────────────────────────────────────────────────
section "Pre-pulling images on workers"

# Pull images one at a time with clear error output so tag issues are obvious
for img in "$IMG_FRONTEND" "$IMG_API" "$IMG_ADMIN" "$IMG_NGINX"; do
  for node in "$W1" "$W2"; do
    info "Pulling $img on $node..."
    if lxc_exec "$node" "docker pull $img"; then
      success "  $node: pulled $img"
    else
      error "  $node: FAILED to pull $img — check the image name/tag and that it is public on Docker Hub"
    fi
  done
  info "Pulling $img on $W3 (Alpine)..."
  if lxc_exec_sh "$W3" "docker pull $img"; then
    success "  $W3: pulled $img"
  else
    error "  $W3: FAILED to pull $img"
  fi
done
success "All images pulled successfully on all workers"

# ─────────────────────────────────────────────────────────────────────────────
#  SECTION 10 — Deploy the stack
# ─────────────────────────────────────────────────────────────────────────────
section "Deploying Atlas stack"

# Remove any existing stack first so we get a clean deploy with correct image tags
if lxc_exec "$MGR" "docker stack ls 2>/dev/null" | grep -q "atlas"; then
  warn "Removing existing 'atlas' stack before redeploying..."
  lxc_exec "$MGR" "docker stack rm atlas"
  info "Waiting for stack to fully remove..."
  sleep 15
fi

lxc_exec "$MGR" "docker stack deploy -c /opt/atlas/stack.yml atlas"
success "Stack deployed as 'atlas'"

# Wait for services to converge
info "Waiting for services to converge (up to 90 seconds)..."
for i in $(seq 1 18); do
  sleep 5
  RUNNING=$(lxc_exec "$MGR" "docker stack services atlas --format '{{.Replicas}}' 2>/dev/null" | grep -c "1/1" || true)
  TOTAL=$(lxc_exec "$MGR" "docker stack services atlas --format '{{.Replicas}}' 2>/dev/null" | wc -l || true)
  info "Services ready: $RUNNING / $TOTAL"
  if [[ "$RUNNING" -eq "$TOTAL" && "$TOTAL" -gt 0 ]]; then
    break
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
#  FINAL STATUS
# ─────────────────────────────────────────────────────────────────────────────
section "Final Swarm Status"

echo ""
echo -e "${BOLD}=== Swarm Nodes ===${RESET}"
lxc_exec "$MGR" "docker node ls"

echo ""
echo -e "${BOLD}=== Stack Services ===${RESET}"
lxc_exec "$MGR" "docker stack services atlas"

echo ""
echo -e "${BOLD}=== Running Containers (per node) ===${RESET}"
lxc_exec "$MGR" "docker stack ps atlas --no-trunc"

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Atlas Swarm is UP${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Manager  : ${CYAN}${MANAGER_IP}${RESET}"
echo -e "  Worker 1 : ${CYAN}${WORKER1_IP}${RESET}  (Ubuntu)"
echo -e "  Worker 2 : ${CYAN}${WORKER2_IP}${RESET}  (Ubuntu)"
echo -e "  Worker 3 : ${CYAN}${WORKER3_IP}${RESET}  (Alpine)"
echo ""
echo -e "  App URL  : ${BOLD}http://${WORKER1_IP}${RESET}  (or any worker IP)"
echo ""
echo -e "${YELLOW}Tip: To watch live container status:${RESET}"
echo -e "  lxc-attach -n ${MGR} -- docker stack ps atlas"
echo ""
echo -e "${YELLOW}Tip: To tear everything down:${RESET}"
echo -e "  lxc-attach -n ${MGR} -- docker stack rm atlas"
echo -e "  lxc-stop -n ${MGR} && lxc-stop -n ${W1} && lxc-stop -n ${W2} && lxc-stop -n ${W3}"
echo ""