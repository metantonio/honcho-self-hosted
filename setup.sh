#!/usr/bin/env bash
set -euo pipefail

# Self-hosted Honcho setup for Hermes Agent
# Usage: curl -sL https://raw.githubusercontent.com/elkimek/honcho-self-hosted/main/setup.sh | bash

REPO="https://github.com/elkimek/honcho-self-hosted.git"
HONCHO_REPO="https://github.com/plastic-labs/honcho.git"
INSTALL_DIR="$HOME/honcho"
CONFIG_DIR="$HOME/honcho-self-hosted"

echo "=== Self-hosted Honcho setup ==="
echo ""

# --- Check Docker ---
if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    echo ""
    echo "Docker installed. You need to log out and back in, then re-run this script."
    exit 0
fi

if ! docker info &>/dev/null; then
    echo "Docker is installed but not accessible. Either:"
    echo "  - Log out and back in (if you just installed Docker)"
    echo "  - Or run: sudo usermod -aG docker $USER"
    exit 1
fi

echo "[1/5] Docker OK ($(docker --version | cut -d' ' -f3 | tr -d ','))"

# --- Clone repos ---
if [ -d "$CONFIG_DIR" ]; then
    echo "[2/5] Config repo exists, pulling latest..."
    git -C "$CONFIG_DIR" pull -q
else
    echo "[2/5] Cloning config repo..."
    git clone -q "$REPO" "$CONFIG_DIR"
fi

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "[3/5] Honcho repo exists, pulling latest..."
    git -C "$INSTALL_DIR" stash -q 2>/dev/null || true
    git -C "$INSTALL_DIR" pull -q
    git -C "$INSTALL_DIR" stash pop -q 2>/dev/null || true
else
    echo "[3/5] Cloning Honcho..."
    git clone -q --depth 1 "$HONCHO_REPO" "$INSTALL_DIR"
fi

# --- Copy configs ---
cp "$CONFIG_DIR/docker-compose.yml" "$INSTALL_DIR/"
cp "$CONFIG_DIR/config.toml" "$INSTALL_DIR/"

# --- API keys ---
if [ -f "$INSTALL_DIR/.env" ]; then
    echo "[4/5] .env exists, keeping current keys"
else
    echo "[4/5] Setting up API keys..."
    echo ""
    read -rp "  OpenRouter API key: " OPENROUTER_KEY
    read -rp "  Venice AI API key (or press Enter to skip): " VENICE_KEY

    cat > "$INSTALL_DIR/.env" <<EOF
# OpenRouter — primary LLM provider
LLM_VLLM_API_KEY=${OPENROUTER_KEY}
LLM_VLLM_BASE_URL=https://openrouter.ai/api/v1

# Venice — backup LLM provider + embeddings
LLM_OPENAI_COMPATIBLE_API_KEY=${VENICE_KEY:-none}

# Needed for client initialization
LLM_OPENAI_API_KEY=${OPENROUTER_KEY}
EOF
    echo "  Keys saved to $INSTALL_DIR/.env"
fi

# --- Start ---
echo "[5/5] Starting Honcho..."
cd "$INSTALL_DIR"
docker compose up -d --build 2>&1 | grep -E 'Started|Built|Pulling|Error' || true

echo ""
echo "Waiting for API..."
for i in $(seq 1 30); do
    if curl -s http://localhost:8000/openapi.json >/dev/null 2>&1; then
        echo "Honcho API is live at http://localhost:8000"
        break
    fi
    sleep 1
done

# --- Hermes config ---
if command -v hermes &>/dev/null; then
    mkdir -p "$HOME/.honcho"
    cp "$CONFIG_DIR/honcho-config.json" "$HOME/.honcho/config.json"
    echo "Hermes configured to use local Honcho"
    echo ""
    echo "Run 'hermes gateway restart' to apply."
else
    echo ""
    echo "Hermes not found. To configure it later:"
    echo "  mkdir -p ~/.honcho"
    echo "  cp $CONFIG_DIR/honcho-config.json ~/.honcho/config.json"
fi

echo ""
echo "Done! Honcho is running on localhost:8000"
