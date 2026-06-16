#!/usr/bin/env bash
# =============================================================================
# PROJECT ATLAS - Verification Script
# =============================================================================
# Run this after: docker compose up --build -d
# Usage: bash scripts/verify.sh
# =============================================================================

set -e

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

echo ""
echo "============================================"
echo " PROJECT ATLAS - System Verification"
echo "============================================"
echo ""

# ---- 1. CONTAINERS RUNNING ----
echo "--- 1. Container Status ---"
for svc in nginx-gateway frontend-service api-service admin-service; do
  state=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  if [ "$state" = "running" ]; then
    pass "$svc is running"
  else
    fail "$svc is NOT running (state: $state)"
  fi
done

echo ""

# ---- 2. POSITIVE TESTS: Routes through Nginx ----
echo "--- 2. Positive Tests (must succeed) ---"

# Frontend
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
if [ "$status" = "200" ]; then
  pass "GET / -> frontend-service (HTTP $status)"
else
  fail "GET / -> expected 200, got $status"
fi

# API users
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/users)
if [ "$status" = "200" ]; then
  pass "GET /api/users -> api-service (HTTP $status)"
else
  fail "GET /api/users -> expected 200, got $status"
fi

# API products
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/products)
if [ "$status" = "200" ]; then
  pass "GET /api/products -> api-service (HTTP $status)"
else
  fail "GET /api/products -> expected 200, got $status"
fi

# API orders
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/orders)
if [ "$status" = "200" ]; then
  pass "GET /api/orders -> api-service (HTTP $status)"
else
  fail "GET /api/orders -> expected 200, got $status"
fi

# Admin
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/admin)
if [ "$status" = "200" ]; then
  pass "GET /admin -> admin-service (HTTP $status)"
else
  fail "GET /admin -> expected 200, got $status"
fi

# Admin health
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/admin/health)
if [ "$status" = "200" ]; then
  pass "GET /admin/health -> admin-service (HTTP $status)"
else
  fail "GET /admin/health -> expected 200, got $status"
fi

# Nginx status
status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/nginx-status)
if [ "$status" = "200" ]; then
  pass "GET /nginx-status -> nginx stub_status (HTTP $status)"
else
  fail "GET /nginx-status -> expected 200, got $status"
fi

echo ""

# ---- 3. NEGATIVE TESTS: Direct access must fail ----
echo "--- 3. Negative Tests (must FAIL - proving isolation) ---"

# api-service port 5000 should NOT be accessible from host
result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:5000/ 2>/dev/null || echo "blocked")
if [ "$result" = "blocked" ] || [ "$result" = "000" ]; then
  pass "SECURITY: api-service:5000 is NOT accessible from host"
else
  fail "SECURITY BREACH: api-service:5000 returned HTTP $result (should be blocked)"
fi

# admin-service port 6000 should NOT be accessible from host
result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:6000/ 2>/dev/null || echo "blocked")
if [ "$result" = "blocked" ] || [ "$result" = "000" ]; then
  pass "SECURITY: admin-service:6000 is NOT accessible from host"
else
  fail "SECURITY BREACH: admin-service:6000 returned HTTP $result (should be blocked)"
fi

# frontend-service port 3000 should NOT be accessible from host
result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:3000/ 2>/dev/null || echo "blocked")
if [ "$result" = "blocked" ] || [ "$result" = "000" ]; then
  pass "SECURITY: frontend-service:3000 is NOT accessible from host"
else
  fail "SECURITY BREACH: frontend-service:3000 returned HTTP $result (should be blocked)"
fi

echo ""

# ---- 4. DNS RESOLUTION from inside nginx ----
echo "--- 4. Docker DNS Resolution (from nginx-gateway) ---"

for svc in frontend-service api-service admin-service; do
  result=$(docker exec nginx-gateway nslookup "$svc" 2>&1 | grep -c "Address" || true)
  if [ "$result" -ge "1" ]; then
    ip=$(docker exec nginx-gateway nslookup "$svc" 2>&1 | grep "Address" | tail -1 | awk '{print $2}')
    pass "DNS: $svc resolves to $ip"
  else
    fail "DNS: $svc does not resolve from nginx-gateway"
  fi
done

echo ""

# ---- 5. NETWORK ISOLATION ----
echo "--- 5. Network Isolation ---"

# api-service cannot reach frontend-service (different networks)
result=$(docker exec api-service wget -qO- http://frontend-service:3000/ --timeout=2 2>&1 || echo "failed")
if echo "$result" | grep -q "failed\|bad address\|refused\|timeout"; then
  pass "ISOLATION: api-service cannot reach frontend-service (cross-network blocked)"
else
  fail "ISOLATION BREACH: api-service reached frontend-service - check network config"
fi

# frontend-service cannot reach api-service (different networks)
result=$(docker exec frontend-service wget -qO- http://api-service:5000/ --timeout=2 2>&1 || echo "failed")
if echo "$result" | grep -q "failed\|bad address\|refused\|timeout"; then
  pass "ISOLATION: frontend-service cannot reach api-service (cross-network blocked)"
else
  fail "ISOLATION BREACH: frontend-service reached api-service - check network config"
fi

echo ""

# ---- 6. NETWORK MEMBERSHIP ----
echo "--- 6. Network Membership ---"

fe_net=$(docker network inspect atlas-frontend-net --format '{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' 2>/dev/null || echo "")
be_net=$(docker network inspect atlas-backend-net  --format '{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' 2>/dev/null || echo "")

for c in nginx-gateway frontend-service; do
  if echo "$fe_net" | grep -q "$c"; then pass "NETWORK: $c is on frontend-net"
  else fail "NETWORK: $c is NOT on frontend-net"; fi
done

for c in nginx-gateway api-service admin-service; do
  if echo "$be_net" | grep -q "$c"; then pass "NETWORK: $c is on backend-net"
  else fail "NETWORK: $c is NOT on backend-net"; fi
done

# Verify nginx is on BOTH networks
if echo "$fe_net" | grep -q "nginx-gateway" && echo "$be_net" | grep -q "nginx-gateway"; then
  pass "MULTI-NET: nginx-gateway is on BOTH frontend-net and backend-net"
else
  fail "MULTI-NET: nginx-gateway is not on both networks"
fi

echo ""

# ---- SUMMARY ----
echo "============================================"
echo " RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}ALL TESTS PASSED - Project Atlas is healthy${NC}"
  exit 0
else
  echo -e "${RED}${FAIL} TEST(S) FAILED - see above for details${NC}"
  exit 1
fi
