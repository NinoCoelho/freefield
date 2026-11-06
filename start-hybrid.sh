#!/usr/bin/env bash
# Freefield Hybrid - Start all services
# Usage: ./start-hybrid.sh

set -euo pipefail

FREEFIELD_ROOT="/Users/nino/Developer/freefield"
COMFY_DIR="$HOME/ComfyUI"
PYTHON_COMFY="/opt/homebrew/bin/python3.11"

# Load environment variables from .env
if [[ -f "$FREEFIELD_ROOT/.env" ]]; then
    set -a
    source "$FREEFIELD_ROOT/.env"
    set +a
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

PID_DIR="$FREEFIELD_ROOT/.pids"
mkdir -p "$PID_DIR"

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Starting Freefield Hybrid${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if already running
if [[ -f "$PID_DIR/comfyui.pid" ]] && kill -0 "$(cat "$PID_DIR/comfyui.pid")" 2>/dev/null; then
    echo -e "${YELLOW}ComfyUI already running (PID: $(cat "$PID_DIR/comfyui.pid"))${NC}"
else
    echo -e "${BLUE}Starting ComfyUI...${NC}"
    cd "$COMFY_DIR"
    nohup "$PYTHON_COMFY" main.py --listen 127.0.0.1 --port 8188 --disable-auto-launch --extra-model-paths-config "$COMFY_DIR/extra_model_paths.yaml" \
        > "$PID_DIR/comfyui.log" 2>&1 &
    echo $! > "$PID_DIR/comfyui.pid"
    echo -e "${GREEN}✓ ComfyUI started (PID: $!)${NC}"
    echo "  Log: $PID_DIR/comfyui.log"
fi

if [[ -f "$PID_DIR/proxy.pid" ]] && kill -0 "$(cat "$PID_DIR/proxy.pid")" 2>/dev/null; then
    echo -e "${YELLOW}comfy-api-proxy already running (PID: $(cat "$PID_DIR/proxy.pid"))${NC}"
else
    echo -e "${BLUE}Starting comfy-api-proxy...${NC}"
    # Enable CORS for Freefield UI (port 3000) to call the proxy (port 8189)
    nohup comfy-api-proxy run --comfyui http://127.0.0.1:8188 --port 8189 --comfyui-base-dir "$COMFY_DIR" --enable-cors-header http://127.0.0.1:3000 \
        > "$PID_DIR/proxy.log" 2>&1 &
    echo $! > "$PID_DIR/proxy.pid"
    echo -e "${GREEN}✓ comfy-api-proxy started (PID: $!)${NC}"
    echo "  Log: $PID_DIR/proxy.log"
fi

if [[ -f "$PID_DIR/ui.pid" ]] && kill -0 "$(cat "$PID_DIR/ui.pid")" 2>/dev/null; then
    echo -e "${YELLOW}Freefield UI already running (PID: $(cat "$PID_DIR/ui.pid"))${NC}"
else
    echo -e "${BLUE}Starting Freefield UI...${NC}"
    cd "$FREEFIELD_ROOT"
    nohup npm run serve \
        > "$PID_DIR/ui.log" 2>&1 &
    echo $! > "$PID_DIR/ui.pid"
    echo -e "${GREEN}✓ Freefield UI started (PID: $!)${NC}"
    echo "  Log: $PID_DIR/ui.log"
fi

echo ""
echo -e "${GREEN}All services started!${NC}"
echo ""
echo "Access:"
echo "  • Freefield UI:  http://127.0.0.1:3000"
echo "  • ComfyUI API:   http://127.0.0.1:8188"
echo "  • comfy-api-proxy: http://127.0.0.1:8189"
echo "  • Modal backend: https://coelho-idemir--freefield-serve.us-east.modal.run"
echo ""
echo "Logs: tail -f $PID_DIR/*.log"
echo "Stop: ./stop-hybrid.sh"
echo ""

# Health checks
echo -e "${BLUE}Waiting for services to be ready...${NC}"
sleep 3

check_service() {
    local name=$1
    local url=$2
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s -f "$url" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ $name is ready${NC}"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    echo -e "${YELLOW}⚠ $name not responding at $url (may still be starting)${NC}"
    return 1
}

check_service "ComfyUI" "http://127.0.0.1:8188/system_stats"
check_service "comfy-api-proxy" "http://127.0.0.1:8189/api/v2/health"
check_service "Freefield UI" "http://127.0.0.1:3000"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Freefield Hybrid is running!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"

# Open browser
if command -v open >/dev/null; then
    echo "Opening http://127.0.0.1:3000 in browser..."
    open "http://127.0.0.1:3000"
elif command -v xdg-open >/dev/null; then
    xdg-open "http://127.0.0.1:3000"
fi