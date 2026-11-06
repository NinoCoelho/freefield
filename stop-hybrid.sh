#!/usr/bin/env bash
# Freefield Hybrid - Stop all services
# Usage: ./stop-hybrid.sh

set -euo pipefail

FREEFIELD_ROOT="/Users/nino/Developer/freefield"
PID_DIR="$FREEFIELD_ROOT/.pids"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Stopping Freefield Hybrid${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""

stop_service() {
    local name=$1
    local pid_file="$PID_DIR/$2.pid"
    local log_file="$PID_DIR/$2.log"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${BLUE}Stopping $name (PID: $pid)...${NC}"
            kill "$pid" 2>/dev/null || true
            # Wait for graceful shutdown
            local count=0
            while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
                sleep 0.5
                ((count++))
            done
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                echo -e "${YELLOW}Force killing $name...${NC}"
                kill -9 "$pid" 2>/dev/null || true
            fi
            echo -e "${GREEN}✓ $name stopped${NC}"
        else
            echo -e "${YELLOW}$name not running (stale PID file)${NC}"
        fi
        rm -f "$pid_file"
    else
        echo -e "${YELLOW}$name: no PID file found${NC}"
    fi
}

stop_service "Freefield UI" "ui"
stop_service "comfy-api-proxy" "proxy"
stop_service "ComfyUI" "comfyui"

# Clean up any remaining processes on the ports
for port in 3000 8189 8188; do
    pid=$(lsof -ti:$port 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        echo -e "${YELLOW}Cleaning up port $port (PID: $pid)${NC}"
        kill -9 "$pid" 2>/dev/null || true
    fi
done

echo ""
echo -e "${GREEN}All services stopped.${NC}"
echo "Logs preserved in: $PID_DIR/"