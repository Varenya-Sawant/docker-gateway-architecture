#!/usr/bin/env bash
# =============================================================================
# PROJECT ATLAS - Diagnosis Script
# =============================================================================
# Run this when something is broken. Dumps everything useful.
# Usage: bash scripts/diagnose.sh
# =============================================================================

echo ""
echo "============================================"
echo " PROJECT ATLAS - Full Diagnosis Dump"
echo "============================================"
echo ""

echo "--- Container Status ---"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "docker not running"

echo ""
echo "--- Container Health ---"
for c in nginx-gateway frontend-service api-service admin-service; do
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$c" 2>/dev/null || echo "not found")
  echo "  $c: $health"
done

echo ""
echo "--- Network List ---"
docker network ls | grep -E "NAME|atlas"

echo ""
echo "--- frontend-net members ---"
docker network inspect atlas-frontend-net --format '{{range $k, $v := .Containers}}  {{$v.Name}}: {{$v.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null || echo "network not found"

echo ""
echo "--- backend-net members ---"
docker network inspect atlas-backend-net --format '{{range $k, $v := .Containers}}  {{$v.Name}}: {{$v.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null || echo "network not found"

echo ""
echo "--- nginx-gateway network interfaces ---"
docker exec nginx-gateway ip addr show 2>/dev/null || echo "container not running"

echo ""
echo "--- nginx-gateway routing table ---"
docker exec nginx-gateway ip route 2>/dev/null || echo "container not running"

echo ""
echo "--- nginx-gateway /etc/resolv.conf ---"
docker exec nginx-gateway cat /etc/resolv.conf 2>/dev/null || echo "container not running"

echo ""
echo "--- DNS Resolution from nginx-gateway ---"
for svc in frontend-service api-service admin-service; do
  echo -n "  $svc -> "
  docker exec nginx-gateway nslookup "$svc" 2>/dev/null | grep "Address" | tail -1 || echo "FAILED"
done

echo ""
echo "--- Nginx config test ---"
docker exec nginx-gateway nginx -t 2>&1 || echo "nginx not running or config invalid"

echo ""
echo "--- Nginx access log (last 10 lines) ---"
docker exec nginx-gateway tail -10 /var/log/nginx/access.log 2>/dev/null || echo "no logs yet"

echo ""
echo "--- Nginx error log (last 10 lines) ---"
docker exec nginx-gateway tail -10 /var/log/nginx/error.log 2>/dev/null || echo "no errors"

echo ""
echo "--- Direct container connectivity from nginx ---"
for svc_port in "frontend-service:3000" "api-service:5000" "admin-service:6000"; do
  svc=$(echo $svc_port | cut -d: -f1)
  port=$(echo $svc_port | cut -d: -f2)
  result=$(docker exec nginx-gateway wget -qO- "http://$svc:$port/" --timeout=3 2>&1 | head -1 || echo "FAILED")
  echo "  nginx -> $svc:$port -> $result"
done

echo ""
echo "--- Port exposure check on host ---"
for port in 80 3000 5000 6000; do
  result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://localhost:$port/" 2>/dev/null || echo "closed")
  echo "  localhost:$port -> $result"
done

echo ""
echo "--- Container logs (last 5 lines each) ---"
for c in nginx-gateway frontend-service api-service admin-service; do
  echo "  [$c]"
  docker logs "$c" --tail 5 2>&1 | sed 's/^/    /' || echo "    no logs"
  echo ""
done

echo "============================================"
echo " Diagnosis complete"
echo "============================================"
