# PROJECT ATLAS
## Docker Networking & Service Discovery Lab
### Complete Learning Guide

---

## What You Are Building

A production-style microservice architecture with:

- **Nginx reverse proxy** as the single public entry point
- **Frontend service** serving HTML (Node.js, port 3000)
- **API service** serving JSON data (Node.js, port 5000)
- **Admin service** with admin panel + health endpoint (Node.js, port 6000)
- **Two isolated Docker networks** for security segmentation

```
Internet
    |
    | :80 (ONLY public port)
    v
nginx-gateway
    |
    |-- /            --> frontend-service:3000  (frontend-net)
    |-- /api/*       --> api-service:5000       (backend-net)
    |-- /admin/*     --> admin-service:6000     (backend-net)

Networks:
  frontend-net: nginx-gateway + frontend-service
  backend-net:  nginx-gateway + api-service + admin-service
```

---

## Folder Structure

```
atlas/
├── docker-compose.yml          <- run everything with one command
├── docker-compose.prod.yml     <- production Compose config
├── GUIDE.md                    <- this file
├── README.md                   <- project overview and setup guide
│
├── nginx-gateway/
│   ├── Dockerfile
│   └── nginx.conf              <- THE most important file to study
│
├── frontend-service/
│   ├── Dockerfile
│   ├── package.json
│   └── app.js
│
├── api-service/
│   ├── Dockerfile
│   ├── package.json
│   └── app.js
│
├── admin-service/
│   ├── Dockerfile
│   ├── package.json
│   └── app.js
│
├── chaos.sh                    <- break/fix scenarios for learning
├── diagnose.sh                 <- full system dump for debugging
└── verify.sh                   <- automated test suite
```

---

## Prerequisites

- Docker installed: `docker --version`
- Docker Compose installed: `docker compose version`
- curl installed: `curl --version`

---

## STEP 1: Start the Project

```bash
# From the atlas/ directory
docker compose up --build

# Or run detached (in background)
docker compose up --build -d
```

Watch the build output. You will see all four images build, then all four containers start.

Expected final output:
```
Container nginx-gateway     Started
Container frontend-service  Started
Container api-service       Started
Container admin-service     Started
```

---

## STEP 2: Verify Everything Works

```bash
# Run the automated test suite
bash verify.sh
```

Expected output: all PASS, 0 FAIL.

If something fails, run:
```bash
bash diagnose.sh
```

---

## STEP 3: Test Manually

Open a browser or use curl:

```bash
# Frontend (HTML page)
curl http://localhost/

# API endpoints (JSON)
curl http://localhost/api/users
curl http://localhost/api/products
curl http://localhost/api/orders

# Admin panel (HTML)
curl http://localhost/admin

# Admin health (JSON)
curl http://localhost/admin/health
```

All traffic goes through port **80** → nginx → the appropriate internal service.
No other port is open.

---

## PHASE 1: Understanding Docker Networking

### What is a network namespace?

Every container gets its own isolated copy of the Linux network stack:
- Its own `lo` (loopback) interface
- Its own `eth0` interface
- Its own routing table
- Its own iptables rules

Two containers cannot communicate unless Docker connects them through a shared bridge.

### What is a veth pair?

A veth (virtual Ethernet) pair is two linked virtual network interfaces. Think of it as a pipe with two ends.

```
Container                         Host
namespace                         namespace
┌─────────────┐                ┌──────────────┐
│    eth0     │ ←── kernel ──→ │  vethXXXXXX  │
└─────────────┘    pipe         └──────┬───────┘
                                       │
                                 docker0 bridge
```

One end lives inside the container (`eth0`). The other end lives on the host and connects to a Linux bridge.

### What is a Linux bridge?

A bridge is a software Layer-2 switch. Docker creates one for each network. All veth host-ends connect to it. Containers on the same bridge can reach each other.

```bash
# See all bridges on the host
ip link show type bridge

# You will see:
# docker0        <- default bridge
# br-abc123      <- atlas-frontend-net
# br-def456      <- atlas-backend-net
```

### How iptables fits in

Docker writes iptables rules to:
1. **MASQUERADE**: let containers reach the internet through the host IP
2. **DNAT**: redirect host port 80 to nginx container port 80
3. **DOCKER-ISOLATION**: prevent packets from crossing between networks

```bash
# See Docker's NAT rules (run on host)
sudo iptables -t nat -L -n -v

# See isolation rules
sudo iptables -L DOCKER-ISOLATION-STAGE-1 -n -v
```

### Default bridge vs custom bridge

| Feature | Default bridge (docker0) | Custom bridge |
|---------|--------------------------|---------------|
| DNS resolution | NO | YES |
| Container discovery by name | NO | YES |
| Isolation from other networks | Partial | Full |
| Automatic creation | Yes (docker installs) | You create it |

**This is the most important distinction.** All containers on the default bridge share it without isolation. Custom bridges give you DNS AND isolation.

---

## PHASE 2: Understanding the Architecture

### Why a reverse proxy?

Without nginx, clients would need to know:
- Frontend is on port 3000
- API is on port 5000
- Admin is on port 6000

That exposes your internal structure. With nginx:
- Clients only know about port 80
- nginx decides who handles each request based on the URL path
- You can move services to different ports/servers without clients knowing

This is the **API Gateway pattern**.

### Why network segmentation?

If api-service had a security vulnerability and an attacker exploited it:

**Without segmentation:** attacker is now in a container that can reach every other container.

**With segmentation (what we built):** attacker is trapped in `backend-net`. They cannot directly reach `frontend-service` because it is on a different network with no route from backend-net.

This is **blast radius reduction**.

### Why DNS names instead of IPs?

Every time a container restarts, Docker may assign it a new IP address.

If nginx.conf said `proxy_pass http://172.19.0.3:5000`, and api-service restarted and got `172.19.0.5`, nginx would keep sending traffic to the dead IP.

With `proxy_pass http://api-service:5000`, Docker DNS resolves the name to the current IP every few seconds. The nginx config never needs to change.

---

## PHASE 3–5: The Services

### Why `0.0.0.0` and not `127.0.0.1`?

Inside a container, `127.0.0.1` is the container's own loopback. If the server binds to `127.0.0.1:3000`, only processes inside the SAME container can connect to it.

nginx lives in a DIFFERENT container. It connects to `frontend-service` through the Docker bridge. That traffic arrives on the container's `eth0` interface, not loopback.

By binding to `0.0.0.0`, the server accepts connections on ALL interfaces — eth0, lo, any future interface.

**Never bind internal services to 127.0.0.1 if you want other containers to reach them.**

### Why EXPOSE in Dockerfile?

`EXPOSE 3000` does NOT publish the port. It is documentation. It tells:
- Humans reading the Dockerfile: "this container expects to receive traffic on 3000"
- Docker Compose and orchestration tools: "this is the default port"

The actual binding happens at `docker run -p 3000:3000` or in `ports:` in docker-compose.yml. We intentionally do NOT do this for internal services.

### Check what your service is doing inside

```bash
# Confirm the process is running
docker exec api-service ps aux

# Confirm it is listening on the right port
docker exec api-service ss -tulpn

# Expected output:
# tcp LISTEN 0 128 0.0.0.0:5000  <- listening on all interfaces
```

---

## PHASE 6: Nginx Gateway — Deep Dive

Open `nginx-gateway/nginx.conf`. Every line is commented. Read all of it. Then come back here.

### The resolver directive

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;
```

`127.0.0.11` is Docker's embedded DNS server. Every container on a custom network can reach it.

`valid=10s` means: after 10 seconds, re-resolve the name. This ensures nginx picks up new IPs after container restarts.

**Without this directive:** nginx resolves upstream names once at startup and caches forever. Container restarts break routing.

### Why variables in proxy_pass?

```nginx
location /api/ {
    set $api_upstream http://api-service:5000;
    proxy_pass $api_upstream;
}
```

When you write `proxy_pass http://api-service:5000` directly (without a variable), nginx resolves `api-service` once at startup. If the container restarts, nginx uses the old IP.

When you use a variable, nginx defers DNS resolution to request time and uses the `resolver` directive's cache. Each request goes through DNS lookup (cached for `valid=` seconds).

This is the correct pattern for production nginx with Docker.

### The rewrite rule explained

```nginx
location /api/ {
    rewrite ^/api/(.*)$ /$1 break;
    proxy_pass $api_upstream;
}
```

Step through a request for `GET /api/users`:

1. Browser sends: `GET /api/users HTTP/1.1`
2. nginx matches `location /api/` block
3. Rewrite: `^/api/(.*)$` matches `/api/users`, captures `users` as `$1`
4. Rewrites URL to `/$1` = `/users`
5. `break` stops further rewrite processing
6. `proxy_pass` forwards `GET /users` to `api-service:5000`
7. api-service receives `GET /users` (no `/api` prefix)

**Without the rewrite:**
- nginx would forward `GET /api/users` to api-service
- api-service has no route for `/api/users`
- You get a 404 from api-service, which nginx returns as a 502 or 404

### proxy_set_header explained

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
```

When nginx proxies a request, it creates a NEW HTTP request to the upstream. That new request would have nginx's IP as the source.

These headers pass the original information forward:
- `Host`: the original Host header (e.g. `localhost`)
- `X-Real-IP`: the actual client IP address
- `X-Forwarded-For`: the chain of IPs if there are multiple proxies

Upstream services use these headers to log the real client IP and enforce access rules.

---

## PHASE 7: Docker DNS Deep Dive

### How Docker DNS works

When you create a custom network and attach a container:

1. Docker assigns the container an IP on that network
2. Docker registers a DNS record: `container-name → IP` in its embedded DNS at `127.0.0.11`
3. Docker writes `nameserver 127.0.0.11` into the container's `/etc/resolv.conf`

Now any container on that network can resolve other containers by name.

### Prove it yourself

```bash
# See what's in nginx's resolv.conf
docker exec nginx-gateway cat /etc/resolv.conf
# nameserver 127.0.0.11
# options ndots:0

# Resolve api-service from nginx
docker exec nginx-gateway nslookup api-service
# Server: 127.0.0.11
# Name:   api-service
# Address: 172.19.0.x

# Resolve frontend-service from api-service (should FAIL)
docker exec api-service nslookup frontend-service
# nslookup: can't resolve 'frontend-service'
# WHY: api-service is on backend-net. frontend-service is on frontend-net.
#      Docker DNS only resolves containers on the SAME network.
```

### The scope of DNS

DNS records are per-network. A container only knows about other containers on the same network. This is by design — it enforces isolation at the DNS layer too.

```bash
# nginx is on BOTH networks, so it can resolve everything:
docker exec nginx-gateway nslookup frontend-service   # resolves via frontend-net
docker exec nginx-gateway nslookup api-service        # resolves via backend-net
docker exec nginx-gateway nslookup admin-service      # resolves via backend-net
```

### What happens when a container restarts?

```bash
# See current IP of api-service
docker inspect api-service | grep IPAddress

# Restart it
docker restart api-service

# See new IP (may be different)
docker inspect api-service | grep IPAddress

# Resolve again from nginx
docker exec nginx-gateway nslookup api-service
# Gets the NEW IP automatically
```

Docker updates the DNS record on every container start. nginx (with `resolver valid=10s`) will pick up the new IP within 10 seconds.

---

## PHASE 8: Custom Networks

### Create and inspect networks

```bash
# After docker compose up, the networks already exist
docker network ls | grep atlas

# Inspect frontend-net
docker network inspect atlas-frontend-net

# See the Linux bridge it created on the host
ip link show type bridge
ip addr show | grep "br-"
```

### What makes a network "custom"?

The key differences from the default `docker0` bridge:

1. **Isolated subnet**: each custom network gets its own `/16` subnet
2. **Embedded DNS**: containers resolve each other by name
3. **Scoped isolation**: containers on different custom networks cannot communicate

### Internal networks

For the most locked-down backends, you can add `internal: true` to a network in docker-compose.yml:

```yaml
networks:
  backend-net:
    driver: bridge
    internal: true   # no external routing, cannot reach internet
```

An internal network has no default gateway. Containers on it cannot ping 8.8.8.8 or reach any external IP.

```bash
# Test (after adding internal: true and recreating)
docker exec api-service ping 8.8.8.8
# ping: connect: Network is unreachable
```

---

## PHASE 9: Network Membership

### See who is on which network

```bash
# frontend-net members
docker network inspect atlas-frontend-net \
  --format '{{range $k, $v := .Containers}}{{$v.Name}}: {{$v.IPv4Address}}{{"\n"}}{{end}}'

# backend-net members
docker network inspect atlas-backend-net \
  --format '{{range $k, $v := .Containers}}{{$v.Name}}: {{$v.IPv4Address}}{{"\n"}}{{end}}'
```

### nginx-gateway is multi-homed

nginx sits on both networks. Inside the container, you can see both interfaces:

```bash
docker exec nginx-gateway ip addr show
# eth0: 172.18.0.x/16  <- frontend-net
# eth1: 172.19.0.x/16  <- backend-net

docker exec nginx-gateway ip route
# default via 172.18.0.1 dev eth0
# 172.18.0.0/16 dev eth0   <- route for frontend-net
# 172.19.0.0/16 dev eth1   <- route for backend-net
```

When nginx resolves `frontend-service` and connects, the packet goes out `eth0` (frontend-net route).
When nginx resolves `api-service` and connects, the packet goes out `eth1` (backend-net route).

The routing table inside nginx is what bridges the two networks.

---

## PHASE 10: Verification

### Full verification

```bash
bash verify.sh
```

### Manual verification — understand each step

```bash
# 1. Check all containers are running
docker compose ps

# 2. Check health status
docker ps --format "table {{.Names}}\t{{.Status}}"

# 3. Test every endpoint
curl -v http://localhost/              # -v shows headers
curl -v http://localhost/api/users
curl -v http://localhost/api/products
curl -v http://localhost/api/orders
curl -v http://localhost/admin
curl -v http://localhost/admin/health

# 4. Verify nginx logs show the upstream that served each request
docker logs nginx-gateway --tail 20
# Log format: request | status | upstream_addr | upstream_status

# 5. Verify internal services are not accessible from host
curl --connect-timeout 2 http://localhost:3000/   # should fail
curl --connect-timeout 2 http://localhost:5000/   # should fail
curl --connect-timeout 2 http://localhost:6000/   # should fail
```

---

## PHASE 11: Network Inspection Commands

These commands are your debugging toolkit. Practice running all of them.

```bash
# ---- DOCKER LEVEL ----

# All networks
docker network ls

# Detailed info on a specific network
docker network inspect atlas-backend-net

# All containers and their IPs
docker inspect --format '{{.Name}}: {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  nginx-gateway frontend-service api-service admin-service

# ---- HOST LEVEL ----

# All network interfaces (including docker bridges)
ip link show

# IP addresses on all interfaces
ip addr show

# Routing table on host
ip route

# Docker's NAT rules (how port 80 gets redirected)
sudo iptables -t nat -L -n -v | grep -E "80|DNAT"

# ---- CONTAINER LEVEL ----

# Interfaces inside nginx
docker exec nginx-gateway ip addr show
docker exec nginx-gateway ip route

# What's listening on what port
docker exec api-service ss -tulpn

# DNS configuration
docker exec nginx-gateway cat /etc/resolv.conf
docker exec nginx-gateway cat /etc/hosts

# DNS resolution
docker exec nginx-gateway nslookup api-service
docker exec nginx-gateway nslookup frontend-service

# Connectivity test
docker exec nginx-gateway ping -c 2 api-service
docker exec nginx-gateway wget -qO- http://api-service:5000/users
```

---

## PHASE 12: Break the System

Run each chaos scenario, observe the failure, then fix it.

```bash
# SCENARIO 1: Disconnect api-service from backend-net
bash chaos.sh break 1

# Observe:
curl http://localhost/api/users          # 502 Bad Gateway
docker logs nginx-gateway --tail 5      # connect() failed
docker exec nginx-gateway nslookup api-service  # may resolve but connect fails

# Fix:
bash chaos.sh fix 1


# SCENARIO 2: Stop api-service container
bash chaos.sh break 2

# Observe:
curl http://localhost/api/users          # 502
docker exec nginx-gateway nslookup api-service  # NXDOMAIN (container gone, no DNS record)
docker exec nginx-gateway wget http://api-service:5000/ --timeout=2  # fails

# Fix:
bash chaos.sh fix 2


# SCENARIO 3: Rename api-service (breaks DNS)
bash chaos.sh break 3

# Observe:
curl http://localhost/api/users          # 502
docker exec nginx-gateway nslookup api-service       # NXDOMAIN
docker exec nginx-gateway nslookup api-service-renamed  # resolves, but nginx.conf says api-service

# Fix:
bash chaos.sh fix 3


# SCENARIO 4: Break nginx config
bash chaos.sh break 4

# Observe:
docker exec nginx-gateway nginx -t      # config test fails
docker exec nginx-gateway nginx -s reload  # fails
# nginx keeps serving from last good config until it's restarted
curl http://localhost/  # may still work (old worker processes)

# Fix:
bash chaos.sh fix 4
```

### What each failure teaches you

| Scenario | Error | Root cause | Lesson |
|----------|-------|------------|--------|
| Disconnect from network | 502 / connection refused | Network route gone | Networks, not just containers, must be in scope |
| Stop container | 502 / DNS NXDOMAIN | No process listening | Health checks detect this |
| Rename container | 502 / DNS NXDOMAIN | DNS name changed | Service names must be stable; use compose service names |
| Bad nginx config | nginx -t fails | Config syntax error | Always `nginx -t` before reload |

---

## PHASE 13: Security Validation

### Prove internal services are not exposed

```bash
# Port scan the host - only port 80 should be open
nmap -p 80,3000,5000,6000 localhost

# Expected:
# 80/tcp   open
# 3000/tcp closed
# 5000/tcp closed
# 6000/tcp closed

# Direct connection attempts (should all fail)
curl --connect-timeout 2 http://localhost:5000/users
curl --connect-timeout 2 http://localhost:6000/admin

# Check what ports are actually published
docker ps --format "table {{.Names}}\t{{.Ports}}"
# Only nginx-gateway should show 0.0.0.0:80->80/tcp
```

### Prove network isolation

```bash
# Can api-service reach frontend-service? NO.
docker exec api-service wget -qO- http://frontend-service:3000/ --timeout=3
# wget: bad address 'frontend-service'
# (frontend-service is on frontend-net, api-service is not on that network,
#  so Docker DNS doesn't even resolve the name from api-service's perspective)

# Can frontend-service reach api-service? NO.
docker exec frontend-service wget -qO- http://api-service:5000/ --timeout=3
# wget: bad address 'api-service'

# Can nginx reach both? YES (it's on both networks).
docker exec nginx-gateway wget -qO- http://frontend-service:3000/ | head -1
docker exec nginx-gateway wget -qO- http://api-service:5000/users | head -1
docker exec nginx-gateway wget -qO- http://admin-service:6000/health
```

### How Docker enforces isolation

Docker adds iptables rules in the `DOCKER-ISOLATION-STAGE-1` and `DOCKER-ISOLATION-STAGE-2` chains:

```bash
sudo iptables -L DOCKER-ISOLATION-STAGE-1 -n -v
```

These rules drop packets that try to move from one Docker network's bridge to another Docker network's bridge — unless the packet goes through a container that is connected to both networks.

nginx-gateway is that container. It is the only legitimate path between the two networks.

---

## PHASE 14: Docker Compose — How It Works

### What `docker compose up --build` does

1. Reads `docker-compose.yml`
2. Creates networks defined in `networks:` section
3. Builds images from `build: ./service-folder` directives
4. Starts containers in dependency order (`depends_on:`)
5. Attaches each container to its defined networks
6. Registers DNS records for all container names

### Service name = DNS name

In docker-compose.yml, the key under `services:` becomes the DNS name:

```yaml
services:
  api-service:      # <- this is the DNS name
    ...
```

Inside any container on the same network, `nslookup api-service` resolves because the service key is `api-service`.

### depends_on vs healthcheck

`depends_on` controls **start order** only. It does NOT wait for a service to be ready.

With `condition: service_healthy`, Docker waits until the container's HEALTHCHECK reports healthy before starting the dependent container.

In our docker-compose.yml, nginx-gateway has:
```yaml
depends_on:
  frontend-service:
    condition: service_healthy
  api-service:
    condition: service_healthy
  admin-service:
    condition: service_healthy
```

This means nginx only starts after all three backends are healthy. No more 502 on startup due to race conditions.

### Useful Compose commands

```bash
# Start everything (build images first)
docker compose up --build

# Start in background
docker compose up --build -d

# View logs (all services)
docker compose logs -f

# View logs (one service)
docker compose logs -f api-service

# Restart one service (without rebuilding)
docker compose restart api-service

# Rebuild and restart one service
docker compose up --build -d api-service

# See container status
docker compose ps

# Stop everything (containers removed, networks removed)
docker compose down

# Stop + remove volumes
docker compose down -v

# Execute command inside a running service container
docker compose exec api-service sh
```

---

## PHASE 15: Production Patterns

### What this project already does right

- Non-root user in Dockerfiles (security)
- HEALTHCHECK in every Dockerfile
- `depends_on: condition: service_healthy` in compose
- Log rotation (`max-size`, `max-file`)
- `restart: unless-stopped` for resilience
- `server_tokens off` in nginx (hides version)
- `resolver` directive for dynamic DNS in nginx
- Variables in `proxy_pass` for runtime DNS resolution
- Resource limits (`mem_limit`) on each container

### What production would add

**TLS termination at nginx:**
```nginx
server {
    listen 443 ssl;
    ssl_certificate     /etc/ssl/certs/cert.pem;
    ssl_certificate_key /etc/ssl/private/key.pem;
    ...
}
```

**Rate limiting:**
```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
location /api/ {
    limit_req zone=api burst=20 nodelay;
    ...
}
```

**Environment-specific config (no hardcoded values):**
```yaml
# docker-compose.yml
environment:
  - NODE_ENV=production
  - PORT=5000
```

**Secrets management (not env vars in compose):**
```yaml
secrets:
  db_password:
    external: true
```

### Kubernetes equivalents

| Docker concept | Kubernetes equivalent |
|---------------|----------------------|
| Custom bridge network | Namespace + NetworkPolicy |
| Docker DNS (api-service) | CoreDNS (api-service.default.svc.cluster.local) |
| nginx-gateway | Ingress controller (nginx-ingress, traefik) |
| docker compose service | Deployment + Service |
| depends_on: service_healthy | initContainers or readinessProbe |
| internal: true network | NetworkPolicy: deny all egress |
| HEALTHCHECK | livenessProbe + readinessProbe |
| mem_limit | resources.limits.memory |

---

## PHASE 16: Final Validation Checklist

Run through every item. If you can check it off AND explain why, you understand the concept.

```bash
# Run the full automated validation
bash verify.sh
```

### Manual checklist

```
[ ] All 4 containers are running
    docker compose ps

[ ] Docker DNS works (from nginx-gateway)
    docker exec nginx-gateway nslookup frontend-service
    docker exec nginx-gateway nslookup api-service
    docker exec nginx-gateway nslookup admin-service

[ ] nginx routes all three paths correctly
    curl http://localhost/           -> Frontend Dashboard
    curl http://localhost/api/users  -> JSON array
    curl http://localhost/admin      -> Admin Panel HTML

[ ] Only port 80 is exposed to the host
    docker ps --format "table {{.Names}}\t{{.Ports}}"
    curl --connect-timeout 2 http://localhost:5000/  -> fails
    curl --connect-timeout 2 http://localhost:6000/  -> fails

[ ] nginx-gateway is on both networks
    docker exec nginx-gateway ip addr show
    (should show eth0 and eth1 with different subnets)

[ ] Network isolation holds
    docker exec api-service nslookup frontend-service  -> fails
    docker exec frontend-service nslookup api-service  -> fails

[ ] Health checks all pass
    docker ps --format "table {{.Names}}\t{{.Status}}"
    (should show "healthy" for all containers)

[ ] nginx config is valid
    docker exec nginx-gateway nginx -t

[ ] nginx logs show correct upstream routing
    docker logs nginx-gateway --tail 10
    (upstream: field shows which container served each request)

[ ] You can explain the packet journey for: curl http://localhost/api/users
    1. curl sends TCP SYN to host:80
    2. Host iptables DNAT rule redirects to nginx-gateway container:80
    3. nginx receives GET /api/users
    4. nginx matches location /api/ block
    5. Rewrite changes /api/users to /users
    6. nginx resolves "api-service" via 127.0.0.11 -> 172.19.0.x
    7. nginx sends GET /users to 172.19.0.x:5000 via eth1 (backend-net)
    8. api-service receives GET /users, returns JSON
    9. nginx forwards JSON response back to client
```

---

## Troubleshooting Reference

### 502 Bad Gateway

nginx reached the upstream address but got no response, or connection was refused.

```bash
# Step 1: Check if the upstream container is running
docker compose ps

# Step 2: Test direct connection from nginx
docker exec nginx-gateway wget -qO- http://api-service:5000/

# Step 3: Check DNS
docker exec nginx-gateway nslookup api-service

# Step 4: Check nginx logs
docker logs nginx-gateway --tail 20
# Look for: "connect() failed (111: Connection refused)"
# or:       "no live upstreams while connecting to upstream"
```

### 504 Gateway Timeout

nginx connected to the upstream but the upstream didn't respond in time.

```bash
# Check if the upstream is stuck/overloaded
docker exec api-service ps aux
docker stats api-service
```

### DNS not resolving

```bash
# Check the container is on the right network
docker network inspect atlas-backend-net | grep api-service

# Check resolv.conf
docker exec nginx-gateway cat /etc/resolv.conf
# Must show: nameserver 127.0.0.11

# If container not on network, reconnect it
docker network connect atlas-backend-net api-service
```

### Container exits immediately

```bash
# See why it crashed
docker logs <container-name>

# See exit code
docker inspect <container-name> | grep ExitCode
```

### nginx config won't reload

```bash
# Test config before reloading
docker exec nginx-gateway nginx -t

# If config is in the image, rebuild the container
docker compose up --build -d nginx-gateway
```

### Port already in use on host

```bash
# Find what's using port 80
sudo lsof -i :80
sudo ss -tulpn | grep :80

# Or change the host port in docker-compose.yml
ports:
  - "8080:80"   # use localhost:8080 instead
```

---

## Interview Questions & Answers

**Q: What is the difference between EXPOSE in a Dockerfile and -p in docker run?**

A: `EXPOSE` is documentation only. It tells humans and tools what port the container uses internally, but does not publish anything. `-p 80:80` (or `ports:` in compose) actually creates the iptables DNAT rule that forwards traffic from the host port to the container port. You can run a container with EXPOSE but no -p and it will still be unreachable from the host.

---

**Q: Why can't two containers on different custom bridge networks communicate?**

A: Docker adds iptables rules in the DOCKER-ISOLATION chains that DROP packets trying to cross from one bridge to another. Each bridge is a separate Layer-2 domain with its own subnet. There is no IP route between them unless a container is attached to both networks (like nginx-gateway is in this project).

---

**Q: A container restarts and gets a new IP. How does nginx route to it correctly?**

A: With the `resolver 127.0.0.11 valid=10s` directive and upstream variables (`set $upstream http://api-service:5000`), nginx defers DNS resolution to request time and re-resolves every `valid` seconds. Docker's embedded DNS updates the record when the container restarts. Within 10 seconds, nginx is routing to the new IP without any config change.

---

**Q: What is the API gateway pattern?**

A: A single entry point (nginx) that all clients talk to. It routes requests to the appropriate backend service based on URL path, headers, or other HTTP attributes. It provides: a stable external interface even when internal services change, a single place to enforce TLS, auth, rate limiting, and logging, and the ability to change backend topology without client changes.

---

**Q: Explain the rewrite rule: `rewrite ^/api/(.*)$ /$1 break;`**

A: The regex `^/api/(.*)$` matches any path starting with `/api/` and captures everything after it as group 1 (`$1`). The replacement `/$1` strips the `/api` prefix. `break` stops further rewrite processing and uses the new URL. So `/api/users` becomes `/users` before being proxied to api-service, which only knows about `/users`.

---

**Q: What is Docker's embedded DNS and what IP does it listen on?**

A: Docker's embedded DNS resolver listens on `127.0.0.11` inside every container on a custom bridge network. It maintains A records for every container name on that network and updates them dynamically when containers start, stop, or restart. Each container's `/etc/resolv.conf` points to `127.0.0.11` as the nameserver.

---

**Q: How would you implement this in Kubernetes?**

A: 
- Docker custom networks → Kubernetes Namespaces with NetworkPolicies
- nginx-gateway → Ingress controller (e.g., nginx-ingress or Traefik)
- Services communicate by DNS: `api-service.default.svc.cluster.local` (CoreDNS)
- `docker compose up` → `kubectl apply -f` with Deployment + Service manifests
- HEALTHCHECK → livenessProbe and readinessProbe in pod spec
- Network segmentation → NetworkPolicy with podSelector rules

---

## Quick Reference Card

```
# START
docker compose up --build -d

# VERIFY
bash verify.sh

# DIAGNOSE
bash diagnose.sh

# CHAOS
bash chaos.sh break 1
bash chaos.sh fix 1

# LOGS
docker logs nginx-gateway -f
docker logs api-service -f

# ENTER CONTAINER
docker exec -it nginx-gateway sh
docker exec -it api-service sh

# DNS FROM NGINX
docker exec nginx-gateway nslookup api-service
docker exec nginx-gateway nslookup frontend-service

# STOP
docker compose down
```

---

*Project Atlas — Docker Networking & Service Discovery Lab*
*Focus: Nginx reverse proxy, Docker DNS, network segmentation*
