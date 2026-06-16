#!/usr/bin/env bash
# =============================================================================
# PROJECT ATLAS - Chaos / Break Script
# =============================================================================
# Intentionally break the system to learn failure modes.
# Run each scenario, observe the failure, then run the fix.
#
# Usage:
#   bash scripts/chaos.sh break <scenario>
#   bash scripts/chaos.sh fix   <scenario>
#
# Scenarios: 1 2 3 4
# =============================================================================

SCENARIO=$2

print_header() {
  echo ""
  echo "============================================"
  echo " CHAOS: $1"
  echo "============================================"
  echo ""
}

case "$1-$SCENARIO" in

  # SCENARIO 1: Disconnect api-service from backend-net
  break-1)
    print_header "Disconnect api-service from backend-net"
    echo "What will break: /api/* routes through nginx will return 502"
    echo "Why: nginx can no longer reach api-service (different network)"
    echo ""
    docker network disconnect atlas-backend-net api-service
    echo "Disconnected. Now test:"
    echo "  curl http://localhost/api/users"
    echo "  docker logs nginx-gateway --tail 5"
    echo "  docker exec nginx-gateway nslookup api-service"
    ;;

  fix-1)
    print_header "Fix: Reconnect api-service to backend-net"
    docker network connect atlas-backend-net api-service
    echo "Reconnected. Verifying..."
    sleep 1
    curl -s http://localhost/api/users | head -c 100
    echo ""
    echo "Fixed."
    ;;

  # SCENARIO 2: Stop api-service container
  break-2)
    print_header "Stop api-service container"
    echo "What will break: /api/* returns 502"
    echo "DNS may still briefly return old IP, but no process listens there"
    echo ""
    docker stop api-service
    echo "Stopped. Now test:"
    echo "  curl http://localhost/api/users"
    echo "  docker exec nginx-gateway nslookup api-service  (may return nothing)"
    ;;

  fix-2)
    print_header "Fix: Start api-service container"
    docker start api-service
    echo "Started. Waiting for health check..."
    sleep 5
    curl -s http://localhost/api/users | head -c 100
    echo ""
    ;;

  # SCENARIO 3: Rename api-service (breaks DNS)
  break-3)
    print_header "Rename api-service container"
    echo "What will break: nginx config says 'api-service' but container is now named differently"
    echo "DNS will return NXDOMAIN for 'api-service'"
    echo ""
    docker rename api-service api-service-renamed
    echo "Renamed. Now test:"
    echo "  curl http://localhost/api/users"
    echo "  docker exec nginx-gateway nslookup api-service"
    echo "  docker exec nginx-gateway nslookup api-service-renamed"
    ;;

  fix-3)
    print_header "Fix: Rename back"
    docker rename api-service-renamed api-service
    echo "Renamed back. DNS record restored."
    sleep 1
    curl -s http://localhost/api/users | head -c 100
    echo ""
    ;;

  # SCENARIO 4: Break nginx config
  break-4)
    print_header "Inject bad nginx config"
    echo "What will break: nginx -s reload fails, nginx serves stale config or stops"
    echo ""
    docker exec nginx-gateway sh -c "echo 'INVALID CONFIG;' >> /etc/nginx/nginx.conf"
    docker exec nginx-gateway nginx -t 2>&1 || true
    echo ""
    echo "Config is now invalid. Try:"
    echo "  docker exec nginx-gateway nginx -s reload"
    echo "  docker logs nginx-gateway --tail 5"
    ;;

  fix-4)
    print_header "Fix: Recreate nginx-gateway from image"
    echo "Since we can't edit the file (it's baked in the image), recreate the container"
    docker rm -f nginx-gateway
    docker compose up -d nginx-gateway
    echo "Recreated. Testing..."
    sleep 2
    curl -s -o /dev/null -w "nginx-gateway: HTTP %{http_code}\n" http://localhost/
    ;;

  *)
    echo "Usage: bash scripts/chaos.sh [break|fix] [1|2|3|4]"
    echo ""
    echo "Scenarios:"
    echo "  1 - Disconnect api-service from network (break/fix)"
    echo "  2 - Stop api-service container (break/fix)"
    echo "  3 - Rename api-service container (DNS breaks)"
    echo "  4 - Inject bad nginx config"
    echo ""
    echo "Example: bash scripts/chaos.sh break 1"
    echo "         bash scripts/chaos.sh fix 1"
    ;;
esac
