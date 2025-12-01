#!/bin/bash
# Description: Installs wyoming-onnx-asr as a systemd service using CPU on Debian 12 LXC.
# Target OS: Debian 12 (Proxmox LXC)

# --- CONFIGURATION ---
REPO_URL="https://github.com/tboby/wyoming-onnx-asr.git"
INSTALL_DIR="/opt/wyoming-onnx-asr"
SERVICE_USER="wyoming-asr"
SERVICE_PORT="10400"
SERVICE_NAME="wyoming-onnx-asr"

# Environment Variables for CPU deployment
ONNX_ASR_MODEL="nemo-parakeet-tdt-0.6b-v2"
ONNX_ASR_LANGUAGE="en"
ONNX_ASR_PROVIDER="CPUExecutionProvider"

# --- PRE-REQUISITES & SYSTEM SETUP ---
echo "--- Step 1: Updating system and installing prerequisites ---"

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root. Please ensure you are running it as the 'root' user."
  exit 1
fi

# Install core packages: git, python3, venv
apt update && apt install -y git python3 python3-venv

# Create dedicated service user and installation directory
if ! id "${SERVICE_USER}" &>/dev/null; then
    echo "Creating service user: ${SERVICE_USER}"
    useradd --system --no-create-home "${SERVICE_USER}"
fi

# Create installation directory and set ownership
mkdir -p "${INSTALL_DIR}"
chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${INSTALL_DIR}"

# --- INSTALLATION ---
echo "--- Step 2: Cloning repository and installing dependencies ---"
git clone "${REPO_URL}" "${INSTALL_DIR}"
chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${INSTALL_DIR}" 

# Execute VENV and PIP commands using 'su' to run as the service user, 
# ensuring the directory context is correct.
echo "Creating VENV and installing Python dependencies under user ${SERVICE_USER}..."
su - "${SERVICE_USER}" -s /bin/bash -c "
  cd ${INSTALL_DIR} &&
  python3 -m venv .venv &&
  ./.venv/bin/pip install --upgrade pip &&
  ./.venv/bin/pip install --no-cache-dir -r requirements.txt
"

# --- SYSTEMD SERVICE SETUP ---
echo "--- Step 3: Creating systemd service file ---"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat <<EOF > ${SERVICE_FILE}
[Unit]
Description=Wyoming ONNX ASR Service (CPU)
After=network.target

[Service]
# Service runs as the dedicated non-root user
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
Environment="ONNX_ASR_MODEL=${ONNX_ASR_MODEL}"
Environment="ONNX_ASR_LANGUAGE=${ONNX_ASR_LANGUAGE}"
Environment="ONNX_ASR_PROVIDER=${ONNX_ASR_PROVIDER}"
ExecStart=${INSTALL_DIR}/.venv/bin/wyoming-onnx-asr --uri "tcp://0.0.0.0:${SERVICE_PORT}"
Restart=always
RestartSec=5

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- START SERVICE & VERIFICATION ---
echo "--- Step 4: Enabling, starting, and verifying the service ---"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

# Add a brief delay to allow the service to try and start (and potentially fail)
sleep 5 

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "✅ Success! Service ${SERVICE_NAME} (CPU) is running and active."
else
    echo "❌ ERROR! Service ${SERVICE_NAME} failed to start. Review logs for details."
fi

echo "To check the service status and troubleshoot, use the command below:"
echo "journalctl -u ${SERVICE_NAME} --since '5 minutes ago' -e"
