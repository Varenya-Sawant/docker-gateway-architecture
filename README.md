# Atlas - Microservices Architecture with Security & Network Isolation

A production-ready microservices learning project demonstrating **Docker Compose**, **Nginx reverse proxy**, **network segmentation**, and **container security hardening**.

---

## 📋 Table of Contents

1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Services](#services)
4. [Security Features](#security-features)
5. [Network Segmentation](#network-segmentation)
6. [Getting Started](#getting-started)
7. [API Endpoints](#api-endpoints)
8. [Testing & Verification](#testing--verification)
9. [Learning Points](#learning-points)

---

## 🎯 Project Overview

**Atlas** is a containerized microservices system designed to teach:
- Microservices architecture patterns
- Docker Compose orchestration
- Nginx reverse proxy routing
- Network isolation and security
- Container hardening (capability dropping, privilege restrictions)
- Layer 2 (network) security design

The project consists of three backend services (API, Admin, Frontend) behind a single Nginx gateway, with strict network isolation to prevent unauthorized communication.

---

## 🏗️ Architecture

### Logical Diagram

```
┌─────────────────────────────────────────────────┐
│                   INTERNET                      │
│              (Client Requests :80)              │
└────────────────────┬────────────────────────────┘
                     │
        ┌────────────▼──────────────┐
        │   NGINX Gateway           │
        │   (Reverse Proxy)         │
        │   Port 80                 │
        └──────┬──────────┬─────────┘
               │          │
    ┌──────────▼─┐    ┌───▼──────────────────┐
    │ Frontend   │    │   Backend Network    │
    │ Network    │    │   (Internal)         │
    │ ┌────────┐ │    │ ┌──────────────────┐ │
    │ │Frontend│ │    │ │ API Service      │ │
    │ │Service │ │    │ │ :5000            │ │
    │ │:3000   │ │    │ ├──────────────────┤ │
    │ └────────┘ │    │ │ Admin Service    │ │
    └────────────┘    │ │ :6000            │ │
                      │ └──────────────────┘ │
                      └──────────────────────┘
```

### Network Tiers

| Network | Purpose | Isolation | Services |
|---------|---------|-----------|----------|
| **DMZ** | Internet-facing | `internal: false` | nginx-gateway |
| **frontend-net** | Client UI | `internal: true` | frontend-service |
| **backend-net** | Business logic | `internal: true` | api-service, admin-service |

---

## 🚀 Services

### 1. **Nginx Gateway** (Port 80)
- **Role**: Reverse proxy and single entry point
- **Routes**:
  - `/` → frontend-service:3000
  - `/api/` → api-service:5000
  - `/admin/` → admin-service:6000
- **Features**: Header forwarding, traffic routing, security hardening

### 2. **Frontend Service** (Port 3000)
- **Role**: Client-facing UI dashboard
- **Endpoints**:
  - `GET /` → HTML dashboard
- **Network**: frontend-net only
- **Isolation**: Cannot reach backend directly or internet

### 3. **API Service** (Port 5000)
- **Role**: Backend data API
- **Endpoints**:
  - `GET /` → Service info
  - `GET /users` → Returns user list
  - `GET /products` → Returns product list
  - `GET /orders` → Returns orders
- **Network**: backend-net only
- **Isolation**: Cannot reach frontend or internet

### 4. **Admin Service** (Port 6000)
- **Role**: Admin panel and health monitoring
- **Endpoints**:
  - `GET /` → Admin UI
  - `GET /admin` → Admin UI (both paths supported)
  - `GET /health` → Health check JSON
  - `GET /admin/health` → Health check JSON
- **Network**: backend-net only
- **Isolation**: Cannot reach frontend or internet

---

## 🔒 Security Features

### Container-Level Security

#### 1. **Capability Dropping**
```yaml
cap_drop:
  - NET_RAW        # Disables ping/ICMP
  - NET_ADMIN      # Prevents network config changes
  - ALL            # Drop all, add only what's needed
```

**Impact**: Backend containers cannot:
- ✅ Ping external hosts (NO NET_RAW)
- ✅ Modify network settings (NO NET_ADMIN)
- ✅ Escalate privileges (no-new-privileges)

**Test verified**: `ping 1.1.1.1` from backend container returns:
```
PING 1.1.1.1 (1.1.1.1): 56 data bytes
ping: operation not permitted
```

#### 2. **Privilege Restrictions**
```yaml
security_opt:
  - no-new-privileges:true
```
Prevents child processes from gaining elevated privileges.

#### 3. **Network Isolation**
```yaml
networks:
  backend-net:
    internal: true                    # No outbound internet access
    driver_opts:
      com.docker.network.bridge.enable_ip_masquerade: "false"
```

**Impact**:
- Backend services cannot route to external networks
- No IP masquerading (NAT) to bypass isolation
- Internal container-to-container communication only

### Architecture-Level Security

#### Traffic Flow (Unidirectional)
```
Internet → Nginx (only entry point)
Nginx ↔ Frontend-service
Nginx ↔ API-service
Nginx ↔ Admin-service
[NO inter-service direct communication]
[NO backend → Internet connections]
```

#### Layer 2 Design Principles
1. **Network Segmentation**: Each tier has its own network
2. **Least Privilege**: Services only access what they need
3. **Defense in Depth**: Multiple layers (network + capability + privilege)
4. **Single Entry Point**: All traffic through Nginx

---

## 🌐 Network Segmentation

### Why This Matters

**Without segmentation:**
- Compromised API service can reach any network
- Services can exfiltrate data to the internet
- Lateral movement between services is trivial

**With segmentation:**
- API service sandboxed to backend-net only
- No internet connectivity for sensitive services
- Admin and API cannot talk directly (design limitation or enhancement?)

### Current Design

| Service | Networks | Can Reach | Cannot Reach |
|---------|----------|-----------|--------------|
| Nginx | frontend-net, backend-net | All services, Internet | (None) |
| Frontend | frontend-net | Nginx (via reverse proxy) | Backend, API, Internet |
| API | backend-net | Nginx, Admin | Frontend, Internet |
| Admin | backend-net | Nginx, API | Frontend, Internet |

---

## 🚀 Getting Started

### Prerequisites
- Docker Engine 20.10+
- Docker Compose 1.29+
- Git (for GitHub push)

### Build & Run

```bash
# Navigate to project directory
cd d:\atlas

# Build all services
docker-compose build

# Start all services
docker-compose up -d

# Verify containers are running
docker-compose ps

# View logs
docker-compose logs -f
```

### Expected Output
```
CONTAINER ID   IMAGE                STATUS              NAMES
abc123         atlas-frontend       Up 5 seconds        atlas-frontend-service-1
def456         atlas-api            Up 5 seconds        atlas-api-service-1
ghi789         atlas-admin          Up 5 seconds        atlas-admin-service-1
jkl012         atlas-nginx          Up 5 seconds        atlas-nginx-gateway-1
```

### Stop Services
```bash
docker-compose down
```

---

## 📡 API Endpoints

### Via Nginx Gateway (Recommended)

**Frontend UI**
```
GET http://localhost/
Response: HTML dashboard
```

**API Service (via reverse proxy)**
```
GET http://localhost/api/
Response: {"service":"api-service","port":5000}

GET http://localhost/api/users
Response: [{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]

GET http://localhost/api/products
Response: [{"id":1,"name":"Widget","price":9.99},{"id":2,"name":"Gadget","price":19.99}]

GET http://localhost/api/orders
Response: [{"id":1,"userId":1,"productId":2,"status":"shipped"}]
```

**Admin Service (via reverse proxy)**
```
GET http://localhost/admin
Response: HTML admin panel

GET http://localhost/admin/health
Response: {"status":"ok","service":"admin-service","uptime":"12.3s"}
```

### Direct Access (Development Only)

⚠️ Direct access only works from host machine; containers cannot access each other's ports directly.

```bash
# From host machine
curl http://localhost:3000    # Frontend
curl http://localhost:5000    # API
curl http://localhost:6000    # Admin
```

---

## ✅ Testing & Verification

### 1. Verify Containers Stay Running

```bash
# Check status
docker-compose ps

# Should show all containers with "Up" status
```

### 2. Verify Network Isolation (Backend Security)

```bash
# Open shell in api-service
docker-compose exec api-service sh

# Try to ping external host (should FAIL)
ping 1.1.1.1
# Output: ping: operation not permitted

# Try to reach frontend-service
ping frontend-service
# Output: network unreachable (different network)

# Exit
exit
```

### 3. Verify Routing Through Nginx

```bash
# Test admin health through nginx
curl http://localhost/admin/health

# Should return JSON:
# {"status":"ok","service":"admin-service","uptime":"X.Xs"}

# Test API through nginx
curl http://localhost/api/users

# Should return JSON user list
```

### 4. Verify Container Logs

```bash
# View all logs
docker-compose logs

# Follow logs for specific service
docker-compose logs -f nginx-gateway

# Follow multiple services
docker-compose logs -f api-service admin-service
```

### 5. Inspect Network

```bash
# List networks
docker network ls | grep atlas

# Inspect backend network
docker network inspect atlas_backend-net

# Verify it's internal
# "Internal": true
```

---

## 📚 Learning Points

### What You've Learned

1. **Container Lifecycle**
   - Containers exit when main process terminates
   - `server.listen()` keeps Node process running
   - Container restart policies (`unless-stopped`)

2. **Nginx as Reverse Proxy**
   - Routing based on URL paths
   - Rewriting and proxying semantics (`proxy_pass http://service:port/`)
   - Header forwarding for client info (X-Real-IP, X-Forwarded-For)

3. **Docker Networking**
   - Bridge networks for inter-container communication
   - `internal: true` for isolation from host network
   - Network naming for service discovery

4. **Security Hardening**
   - Linux capabilities (NET_RAW, NET_ADMIN, etc.)
   - Privilege restrictions (no-new-privileges)
   - Network isolation (internal networks)
   - Defense in depth approach

5. **Architecture Design**
   - Single entry point (Nginx gateway)
   - Network segmentation by trust level
   - Unidirectional traffic flow
   - Least privilege principle

### Key Takeaways

| Concept | Why It Matters |
|---------|----------------|
| **Isolation** | Prevents attack lateral movement; compromised service can't reach others |
| **Capabilities** | Reduces attack surface; service can't perform actions it doesn't need |
| **Single Entry Point** | Centralized security policy; easier to monitor and control traffic |
| **Network Design** | Layer 2 security is foundational; must be correct before Layer 3+ controls |

### Next Steps

1. **Add PostgreSQL**: Implement a data-net with persistent storage
2. **Add Secrets Management**: Use Docker secrets for database passwords
3. **Implement 4-tier Network**: Add dmz-net, monitoring-net
4. **Add Health Checks**: Docker health checks for auto-restart
5. **Implement Logging**: Centralized logging network with ELK stack
6. **Add CI/CD**: GitHub Actions to build and test on push

---

## 📁 Project Structure

```
atlas/
├── README.md                          # This file
├── docker-compose.yml                 # Service definitions & networks
├── nginx-gateway/
│   ├── Dockerfile                     # Nginx base image
│   └── nginx.conf                     # Reverse proxy config
├── frontend-service/
│   ├── Dockerfile                     # Node.js base image
│   ├── app.js                         # Express-like HTTP server
│   └── package.json                   # Dependencies
├── api-service/
│   ├── Dockerfile                     # Node.js base image
│   ├── app.js                         # RESTful API server
│   └── package.json                   # Dependencies
├── admin-service/
│   ├── Dockerfile                     # Node.js base image
│   ├── app.js                         # Admin panel + health check
│   └── package.json                   # Dependencies
├── GUIDE.md                           # Additional documentation
├── docker-compose.prod.yml            # Production config (reserved)
├── verify.sh                          # Verification script
└── diagnose.sh                        # Diagnostic script
```

---

## 🛠️ Troubleshooting

### Containers Keep Restarting

**Symptom**: `docker-compose ps` shows services in restart loop

**Cause**: Process inside container exiting

**Fix**: 
- Check logs: `docker-compose logs <service>`
- Ensure Node app calls `server.listen(PORT)`
- Verify Dockerfile CMD is correct

### Cannot Access Service Through Nginx

**Symptom**: `curl http://localhost/api/users` returns 502 Bad Gateway

**Cause**: Nginx cannot reach upstream service or config is wrong

**Fix**:
- Verify service is running: `docker-compose ps`
- Check nginx logs: `docker-compose logs nginx-gateway`
- Verify upstream name in nginx.conf matches service name in compose
- Test nginx config: `docker exec atlas_nginx-gateway-1 nginx -t`

### Backend Service Can Reach Internet

**Symptom**: `ping 1.1.1.1` succeeds from backend container

**Cause**: Capabilities not properly dropped or network not internal

**Fix**:
- Rebuild images: `docker-compose build`
- Restart services: `docker-compose down && docker-compose up -d`
- Verify cap_drop in docker-compose.yml

### Port Already in Use

**Symptom**: `docker-compose up` fails with "port 80 already in use"

**Fix**:
```bash
# Free port 80
docker ps -a | grep 80
docker stop <container-id>

# Or use different port in docker-compose.yml
# ports:
#   - "8080:80"
```

---



Created as a learning project for understanding microservices, Docker, and network security.

---

## 📖 References

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Nginx Reverse Proxy Guide](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [Linux Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [Container Network Security](https://kubernetes.io/docs/concepts/services-networking/)

---

## 📄 License

MIT License - Feel free to use, modify, and learn from this project.
