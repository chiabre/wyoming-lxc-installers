#!/bin/bash
# Description: Installer for the Wyoming Piper Text-to-Speech (TTS) service on Debian 12.


# ==============================================================================
#                 --- CONSTANTS (FIXED CONFIGURATION) ---
# ==============================================================================

# Git Repository (Source for configuration files/scripts)
REPO_URL="https://github.com/rhasspy/wyoming-piper.git"
SERVICE_NAME_BASE="wyoming-piper"
EXECUTABLE_NAME="wyoming-piper" 

# --- FIXED DEPLOYMENT RESOURCES ---
INSTALL_DIR="/opt/${SERVICE_NAME_BASE}" # Single installation directory
SERVICE_USER="${SERVICE_NAME_BASE}"      # Dedicated system user
SERVICE_PORT="10200"                     # Standard port for Piper
PYTHON_PACKAGE="wyoming-piper"           # PyPI package name

# --- FIXED MODEL/LANGUAGE CONFIGURATION ---
# NOTE: This configuration assumes a specific model is desired.
# The user will need to manually download the ONNX model and .json config file.
MODEL_NAME="en_US-lessac-medium"
MODEL_ARGS="--model-file /opt/piper/models/${MODEL_NAME}.onnx --config-file /opt/piper/models/${MODEL_NAME}.json"
# The TTS service simply needs the model file path and config file path.

# Cache Directories (Located within INSTALL_DIR)
PIP_CACHE="${INSTALL_DIR}/.pip_cache"
HF_HOME="${INSTALL_DIR}/.hf_cache"

# Final service name
SERVICE_NAME="${SERVICE_NAME_BASE}" 

# ==============================================================================
#                 --- EXECUTION FLOW ---
# ==============================================================================

set -e

echo "--- Step 1: PRE-REQUISITES & SYSTEM SETUP ---"

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root."
  exit 1
fi

# Install core packages
apt update && apt install -y git python3 python3-venv adduser

# --- Step 2: INSTALLATION ---
echo "--- Step 2: Cloning repository and installing dependencies ---"

# 1. Create service user (using the proven adduser logic)
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "Creating service user: $SERVICE_USER"
    adduser --system --group --disabled-login "$SERVICE_USER"
fi

# 2. Clone repository (Enforced clean install for idempotency)
echo "Removing old directory and cloning repository..."
rm -rf "$INSTALL_DIR"
git clone "$REPO_URL" "$INSTALL_DIR"

# 3. Fix ownership
chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR"

# 4. Create cache directories
echo "Creating cache directories..."
mkdir -p "$PIP_CACHE" "$HF_HOME"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$PIP_CACHE" "$HF_HOME"

# 5. Build virtualenv and install dependencies as service user
echo "Building VENV and installing Python package: $PYTHON_PACKAGE..."
su "$SERVICE_USER" -s /bin/bash -c "
  cd $INSTALL_DIR
  python3 -m venv .venv
  ./.venv/bin/pip install --upgrade pip --cache-dir $PIP_CACHE
  # Install the main package from PyPI
  ./.venv/bin/pip install --no-cache-dir $PYTHON_PACKAGE --cache-dir $PIP_CACHE
"

# --- Step 3: SYSTEMD SERVICE SETUP ---
echo "--- Step 3: Creating systemd service file ($SERVICE_NAME.service) ---"

cat <<EOF >/etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Wyoming Piper TTS Service
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
# NOTE: HF_HOME is included here in case Piper uses HuggingFace models/dependencies.
Environment="HF_HOME=${HF_HOME}"
# ExecStart now uses the fixed MODEL_ARGS (model file location)
ExecStart=${INSTALL_DIR}/.venv/bin/${EXECUTABLE_NAME} ${MODEL_ARGS} --uri "tcp://0.0.0.0:${SERVICE_PORT}"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- Step 4: START SERVICE & FINAL INSTRUCTIONS ---
echo "--- Step 4: Enabling, starting, and final instructions ---"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo -e "\n--- Installation complete ---"
echo "Service: ${SERVICE_NAME} installed."
echo "⚠️ IMPORTANT: You must manually download the Piper ONNX model and config files to:"
echo "   /opt/piper/models/"
echo "Monitor with: journalctl -u ${SERVICE_NAME} -f"
echo "Wyoming server exposed at: IP:${SERVICE_PORT}"
