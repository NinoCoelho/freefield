#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Freefield Hybrid Setup: Local M4 Max (64 GB) + Modal for heavy apps
# -----------------------------------------------------------------------------
# What this script does:
#   1. Installs Modal CLI and deploys cloud backend (L40S 48 GB) for 5 heavy apps
#   2. Sets up local ComfyUI + custom nodes for ~115 light/medium apps
#   3. Downloads model packs to both Modal volume and local disk
#   4. Configures Freefield to route apps automatically based on VRAM verdict
#   5. Creates .env with both backends
#
# Requirements:
#   - macOS (tested on M4 Max 64 GB)
#   - Python 3.12+, pip, git, node 22+
#   - HF_TOKEN with access to gated repos: LTX-2.5, FLUX 3 Klein
#   - Modal account (free tier works)
#
# Run: chmod +x setup-hybrid.sh && ./setup-hybrid.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

FREEFIELD_ROOT="/Users/nino/Developer/freefield"
COMFY_DIR="$HOME/ComfyUI"
MODELS_DIR="$HOME/ComfyUI/models"
EXTRA_MODEL_PATHS="$HOME/ComfyUI/extra_model_paths.yaml"

echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Freefield Hybrid Setup — Local M4 Max (64 GB) + Modal${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo ""

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
step() { echo -e "\n${BLUE}▶${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; exit 1; }

confirm() {
    read -rp "$(echo -e "${YELLOW}?${NC} $1 [y/N] ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Check prerequisites
# -----------------------------------------------------------------------------
step "Checking prerequisites..."

command -v python3 >/dev/null || err "Python 3 not found"
command -v pip3 >/dev/null || err "pip3 not found"
command -v git >/dev/null || err "git not found"
command -v node >/dev/null || err "Node.js not found (need >=22.6.0)"
command -v npm >/dev/null || err "npm not found"

NODE_VERSION=$(node -v | sed 's/v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
[[ $NODE_MAJOR -ge 22 ]] || err "Node.js >= 22.6.0 required (found $NODE_VERSION)"

ok "Prerequisites met"

# Load environment variables from .env
if [[ -f "$FREEFIELD_ROOT/.env" ]]; then
    set -a
    source "$FREEFIELD_ROOT/.env"
    set +a
fi

# -----------------------------------------------------------------------------
# HF_TOKEN check
# -----------------------------------------------------------------------------
step "Checking Hugging Face token..."
if [[ -z "${HF_TOKEN:-}" ]]; then
    warn "HF_TOKEN not set in environment"
    echo "  You need a token with access to:"
    echo "    - LTX-2.5 (https://huggingface.co/Lightricks/LTX-Video)"
    echo "    - FLUX 3 Klein (https://huggingface.co/black-forest-labs/FLUX.1-Krea-dev)"
    echo ""
    read -rp "Enter HF_TOKEN (or press Enter to skip and set later): " HF_TOKEN_INPUT
    if [[ -n "$HF_TOKEN_INPUT" ]]; then
        export HF_TOKEN="$HF_TOKEN_INPUT"
        ok "HF_TOKEN set for this session"
    else
        warn "Continuing without HF_TOKEN — gated models will fail to download"
    fi
else
    ok "HF_TOKEN found in environment"
fi

# -----------------------------------------------------------------------------
# 1. Modal CLI & Backend Deployment
# -----------------------------------------------------------------------------
step "Setting up Modal backend for heavy apps..."

if ! command -v modal >/dev/null; then
    echo "Installing Modal CLI..."
    pip3 install --upgrade modal
    ok "Modal CLI installed"
    # Ensure modal is in PATH for this session
    export PATH="$HOME/.local/bin:$PATH"
else
    echo "Upgrading Modal CLI..."
    pip3 install --upgrade modal
    ok "Modal CLI upgraded"
fi

# Ensure modal is findable (pip install --user puts it in ~/Library/Python/3.9/bin on macOS)
if ! command -v modal >/dev/null && [[ -f "$HOME/Library/Python/3.9/bin/modal" ]]; then
    export PATH="$HOME/Library/Python/3.9/bin:$PATH"
fi
# Also check ~/.local/bin as fallback
if ! command -v modal >/dev/null && [[ -f "$HOME/.local/bin/modal" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Authenticate with Modal
echo ""
echo "Modal authentication required (opens browser):"
modal token new || err "Modal authentication failed"
ok "Modal authenticated"

# Generate gateway token and create Modal secret
echo ""
echo "Generating gateway token and creating Modal secret 'freefield'..."
cd "$FREEFIELD_ROOT"
python3 tools/setup_token.py || err "Failed to create Modal secret"
ok "Gateway token created and stored in Modal secret 'freefield'"

# Deploy Modal backend (requires payment method for GPU)
echo ""
echo "Attempting to deploy Modal backend..."
echo "Note: Modal free tier requires a payment method for GPU access."
echo "If you haven't added one, deployment will fail and we'll fall back to local-only mode."
echo ""

# Try L40S first, then A10G, then T4
MODAL_URL=""
for GPU in L40S A10G T4; do
    echo "Trying GPU: $GPU..."
    # Capture output to variable, don't fail on non-zero (modal deploy sometimes returns 1 even on success)
    DEPLOY_OUTPUT=$(FREEFIELD_GPU=$GPU MODAL_IMAGE_BUILDER_VERSION=2025.06 modal deploy infra/modal_app.py 2>&1)
    DEPLOY_EXIT=$?
    echo "$DEPLOY_OUTPUT"
    if [[ $DEPLOY_EXIT -eq 0 ]] || echo "$DEPLOY_OUTPUT" | grep -q "App deployed"; then
        # Capture the deployed URL from deploy output (format: "https://xxx--freefield-serve.xxx.modal.run")
        MODAL_URL=$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[^ ]+--freefield-serve\.[^ ]+\.modal\.run' | head -1)
        if [[ -n "$MODAL_URL" ]]; then
            ok "Modal backend deployed with $GPU: $MODAL_URL"
            break
        fi
    else
        warn "Failed with $GPU, trying next..."
    fi
done

if [[ -z "$MODAL_URL" ]]; then
    warn "Modal deployment failed (likely needs payment method for GPU)."
    echo "Falling back to LOCAL-ONLY mode — all apps run on your M4 Max 64 GB."
    echo ""
    echo "To enable Modal later: add payment method at https://modal.com/settings/billing"
    echo "Then re-run: FREEFIELD_GPU=L40S MODAL_IMAGE_BUILDER_VERSION=2025.06 modal deploy infra/modal_app.py"
    
    # Update .env for local-only mode
    sed -i '' 's|^COMFY_BASE_URL=.*|COMFY_BASE_URL=http://127.0.0.1:8189|' "$FREEFIELD_ROOT/.env"
    # Remove or comment out FREEFIELD_MODAL_URL
    sed -i '' '/^FREEFIELD_MODAL_URL=/d' "$FREEFIELD_ROOT/.env"
    
    MODAL_URL="(local-only mode)"
else
    # Update .env with Modal URL
    sed -i '' "s|^FREEFIELD_MODAL_URL=.*|FREEFIELD_MODAL_URL=$MODAL_URL|" "$FREEFIELD_ROOT/.env"
    grep -q "^FREEFIELD_MODAL_URL=" "$FREEFIELD_ROOT/.env" || echo "FREEFIELD_MODAL_URL=$MODAL_URL" >> "$FREEFIELD_ROOT/.env"
fi

# Download model packs to Modal volume (only if Modal backend deployed)
if [[ "$MODAL_URL" != "(local-only mode)" ]]; then
    echo ""
    echo "Downloading model packs to Modal volume (this takes 10-30 min)..."
    echo "Packs for Modal backend (heavy apps):"
    echo "  - video-ltx25 (66 GB) — 33 LTX-based video apps"
    echo "  - video-h3 (76 GB) — 4 H3 video apps (extend-video, h3-photo, h3-video, reshoot)"
    echo "  - video-wan-effects (45 GB) — 5 WAN effect apps"
    echo "  - video-wan-camera (40 GB) — camera-moves"
    echo "  - video-scail (29 GB) — recast"
    echo "  - video-wan (25 GB) — motion-transfer"
    echo "  - image-flux3 (18 GB) — 60 FLUX apps (also needed locally)"
    echo "  - audio (29 GB) — music, sfx"
    echo ""
    confirm "Download ALL packs to Modal now? (takes a while, ~320 GB total)" && \
        MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack video-ltx25 \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack video-h3 \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack video-wan-effects \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack video-wan-camera \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack video-scail \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack video-wan \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack image-flux3 \
        && MODAL_IMAGE_BUILDER_VERSION=2025.06 modal run infra/modal_app.py::download --pack audio \
        || warn "Some packs failed — you can re-run individually later"
    ok "Modal model packs downloaded"
else
    echo ""
    echo "Skipping Modal model downloads (local-only mode)."
fi

# -----------------------------------------------------------------------------
# 2. Local ComfyUI Setup
# -----------------------------------------------------------------------------
step "Setting up local ComfyUI for light/medium apps..."

# Install ComfyUI at pinned commit (requires Python 3.10+)
# Use Homebrew Python 3.11 if available
PYTHON_COMFY="python3"
if command -v python3.11 >/dev/null; then
    PYTHON_COMFY="python3.11"
elif command -v /opt/homebrew/bin/python3.11 >/dev/null; then
    PYTHON_COMFY="/opt/homebrew/bin/python3.11"
fi

# Install ComfyUI at pinned commit
if [[ ! -d "$COMFY_DIR" ]]; then
    echo "Cloning ComfyUI..."
    git clone https://github.com/Comfy-Org/ComfyUI.git "$COMFY_DIR"
    cd "$COMFY_DIR"
    git checkout e3bee7ffcb7d6547ed0bcd15221792f3b8646b17
    $PYTHON_COMFY -m pip install -r requirements.txt
    ok "ComfyUI installed at pinned commit using $PYTHON_COMFY"
else
    ok "ComfyUI already exists at $COMFY_DIR"
fi

# Install custom nodes from packs
step "Installing custom nodes..."
cd "$FREEFIELD_ROOT"
python3 tools/catalog.py packs  # generates packs/*.json with node lists

# Parse custom nodes from packs and install
cat > /tmp/install_nodes.py << 'PYEOF'
import json, subprocess, sys
from pathlib import Path

ROOT = Path("/Users/nino/Developer/freefield")
COMFY_DIR = Path("/Users/nino/ComfyUI")

nodes = {}
for f in sorted((ROOT / "packs").glob("*.json")):
    if f.name == "index.json":
        continue
    try:
        data = json.loads(f.read_text())
        for c in data.get("custom_nodes", []):
            nodes[c["repo"]] = c["commit"]
    except Exception as e:
        print(f"Warning: failed to parse {f}: {e}", file=sys.stderr)

for repo, commit in nodes.items():
    name = repo.rstrip("/").rsplit("/", 1)[-1]
    target = COMFY_DIR / "custom_nodes" / name
    print(f"Installing {name} @ {commit[:8]}...")
    if target.exists():
        subprocess.run(["git", "-C", str(target), "fetch"], check=False)
        subprocess.run(["git", "-C", str(target), "checkout", commit], check=False)
    else:
        subprocess.run(["git", "clone", repo, str(target)], check=True)
        subprocess.run(["git", "-C", str(target), "checkout", commit], check=True)
    req = target / "requirements.txt"
    if req.exists():
        subprocess.run([sys.executable, "-m", "pip", "install", "-r", str(req)], check=False)

print("All custom nodes installed.")
PYEOF
python3 /tmp/install_nodes.py
ok "Custom nodes installed"

# Create extra_model_paths.yaml
step "Creating extra_model_paths.yaml..."
cat > "$EXTRA_MODEL_PATHS" << EOF
freefield:
  base_path: $MODELS_DIR
  diffusion_models: diffusion_models
  text_encoders: text_encoders
  vae: vae
  loras: loras
  checkpoints: checkpoints
  clip_vision: clip_vision
  latent_upscale_models: latent_upscale_models
  upscale_models: upscale_models
  model_patches: model_patches
  geometry_estimation: geometry_estimation
  background_removal: background_removal
  frame_interpolation: frame_interpolation
  audio_encoders: audio_encoders
  embeddings: embeddings
  detection: detection
EOF
ok "Created $EXTRA_MODEL_PATHS"

# Create models directory structure
mkdir -p "$MODELS_DIR"/{diffusion_models,text_encoders,vae,loras,checkpoints,clip_vision,latent_upscale_models,upscale_models,model_patches,geometry_estimation,background_removal,frame_interpolation,audio_encoders,embeddings,detection}
ok "Model directories created"

# -----------------------------------------------------------------------------
# 3. Download Local Model Packs
# -----------------------------------------------------------------------------
step "Downloading model packs locally (for apps running on M4 Max)..."
echo "Packs needed locally (based on VRAM verdict for 64 GB):"
echo "  - upscale (5 GB) — depth-map, remove-bg, smooth, upscale, upscale-video, video-remove-bg"
echo "  - image (12 GB) — z-image"
echo "  - image-flux3 (18 GB) — 60 FLUX apps (ai-influencer, character, headshot, etc.)"
echo "  - image-krea2 (24 GB) — style-reference, styles"
echo "  - image-qwen-edit (32 GB) — angles, relight, shots, whats-next, zooms"
echo "  - video-ltx25 (66 GB) — 33 LTX apps (asmr-*, idol, video, etc.) — fits by phases"
echo "  - video-wan (25 GB) — motion-transfer"
echo "  - video-wan-camera (40 GB) — camera-moves"
echo "  - video-wan-effects (45 GB) — bullet-time-*, effects"
echo "  - video-scail (29 GB) — recast"
echo "  - audio (29 GB) — music, sfx"
echo "  - core (0 GB) — smoke, smoke-invert"
echo "Total: ~325 GB (fits on typical 1-2 TB SSD)"
echo ""
confirm "Download ALL packs locally now? (takes a while)" && \
    cd "$FREEFIELD_ROOT" && \
    python3 -c "
from infra.common import ensure_models
import json, os
token = os.environ.get('HF_TOKEN')
for pack in ['upscale','image','image-flux3','image-krea2','image-qwen-edit','video-ltx25','video-wan','video-wan-camera','video-wan-effects','video-scail','audio','core']:
    try:
        spec = json.load(open(f'packs/{pack}.json'))
        print(f'=== {pack} ===')
        ensure_models(spec['models'], token=token)
    except Exception as e:
        print(f'Failed {pack}: {e}')
" || warn "Some packs failed — re-run individually later"

ok "Local model packs downloaded"

# -----------------------------------------------------------------------------
# 4. Configure Freefield .env
# -----------------------------------------------------------------------------
step "Configuring Freefield .env for hybrid routing..."

cd "$FREEFIELD_ROOT"
if [[ ! -f .env ]]; then
    cp .env.example .env 2>/dev/null || touch .env
fi

# Ensure FREEFIELD_TOKEN is already set by setup_token.py
# Add COMFY_BASE_URL (local) and FREEFIELD_MODAL_URL
grep -q "^COMFY_BASE_URL=" .env 2>/dev/null || echo "COMFY_BASE_URL=http://127.0.0.1:8189" >> .env
grep -q "^FREEFIELD_MODAL_URL=" .env 2>/dev/null || echo "FREEFIELD_MODAL_URL=$MODAL_URL" >> .env

# Update if changed
sed -i '' "s|^COMFY_BASE_URL=.*|COMFY_BASE_URL=http://127.0.0.1:8189|" .env
sed -i '' "s|^FREEFIELD_MODAL_URL=.*|FREEFIELD_MODAL_URL=$MODAL_URL|" .env

ok "Updated .env with both backends"
echo ""
echo "Current .env:"
cat .env

# -----------------------------------------------------------------------------
# 5. Install Freefield dependencies
# -----------------------------------------------------------------------------
step "Installing Freefield npm dependencies..."
cd "$FREEFIELD_ROOT"
npm install
ok "Dependencies installed"

# -----------------------------------------------------------------------------
# 6. Startup instructions
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$MODAL_URL" == "(local-only mode)" ]]; then
    echo -e "${YELLOW}Running in LOCAL-ONLY mode${NC} (Modal requires payment method for GPU)"
    echo ""
    echo "To run Freefield locally:"
    echo ""
    echo "  ${BLUE}# Terminal 1: Local ComfyUI${NC}"
    echo "  cd ~/ComfyUI"
    echo "  python main.py --listen 127.0.0.1 --port 8188 --disable-auto-launch --extra-model-paths-config ~/ComfyUI/extra_model_paths.yaml"
    echo ""
    echo "  ${BLUE}# Terminal 2: comfy-api-proxy${NC}"
    echo "  comfy-api-proxy --comfyui http://127.0.0.1:8188 --port 8189 --comfyui-base-dir ~/ComfyUI"
    echo ""
    echo "  ${BLUE}# Terminal 3: Freefield UI${NC}"
    echo "  cd $FREEFIELD_ROOT"
    echo "  npm run serve"
    echo "  → Open http://127.0.0.1:3000"
    echo ""
    echo "All apps run on your M4 Max 64 GB (VRAM verdicts from docs/vram-map.json):"
    echo "  • Fits whole (< 24 GB): ~80 apps"
    echo "  • Fits by phases (24-39 GB): ~5 apps"
    echo "  • Tight by phases (39-51 GB): ~30 apps"
    echo "  • Needs Modal (50+ GB): 6 apps (dub, extend-video, h3-photo, h3-video, reshoot, cinema-video)"
    echo ""
    echo "To enable Modal later: add payment method at https://modal.com/settings/billing"
    echo "Then re-run: FREEFIELD_GPU=L40S MODAL_IMAGE_BUILDER_VERSION=2025.06 modal deploy infra/modal_app.py"
else
    echo "To run Freefield hybrid:"
    echo ""
    echo "  ${BLUE}# Terminal 1: Local ComfyUI${NC}"
    echo "  cd ~/ComfyUI"
    echo "  python main.py --listen 127.0.0.1 --port 8188 --disable-auto-launch --extra-model-paths-config ~/ComfyUI/extra_model_paths.yaml"
    echo ""
    echo "  ${BLUE}# Terminal 2: comfy-api-proxy${NC}"
    echo "  comfy-api-proxy --comfyui http://127.0.0.1:8188 --port 8189 --comfyui-base-dir ~/ComfyUI"
    echo ""
    echo "  ${BLUE}# Terminal 3: Freefield UI${NC}"
    echo "  cd $FREEFIELD_ROOT"
    echo "  npm run serve"
    echo "  → Open http://127.0.0.1:3000"
    echo ""
    echo "Routing (automatic via docs/vram-map.json):"
    echo "  • Local (64 GB M4 Max): ~115 apps (fits whole, fits by phases, tight)"
    echo "  • Modal (L40S 48 GB): 5 apps (needs Modal: dub, extend-video, h3-photo, h3-video, reshoot, cinema-video)"
    echo ""
    echo "To override routing for an app, edit apps/<id>/app.json and add:"
    echo '  "backend": "local"  // or "modal"'
fi

echo ""
echo -e "${YELLOW}Uninstall guide:${NC} See uninstall.md"