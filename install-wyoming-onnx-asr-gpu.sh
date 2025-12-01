#!/bin/bash
# Description: Installs wyoming-onnx-asr as a systemd service using NVIDIA GPU (CUDA).
# Target OS: Debian 12 (Proxmox LXC)

# --- ⚠️ GPU PREREQUISITES RECAP ⚠️ ---
#
# FOR THIS SCRIPT TO WORK, YOU MUST HAVE ALREADY DONE THE FOLLOWING:
# 1. **Proxmox Host**: Configured GPU passthrough or device mapping for the LXC.
#    (e.g., adding `lxc.cgroup2.devices.allow = c 195:* rwm` and mounting `/dev/nvidia*` in the LXC config).
# 2. **LXC Configuration**: Ensure the LXC is unprivileged or correctly configured for device access.
#
# This script will attempt to install the necessary CUDA **libraries** inside the LXC,
# but the **kernel driver** must be provided by the Proxmox host.
#
# ------------------------------------

# --- CONFIGURATION ---
REPO_URL="https://github.com/tboby/wyoming-onnx-asr.git"
INSTALL_DIR="/opt/wyoming-onnx-asr"
SERVICE_USER="wyoming-asr"
SERVICE_PORT="10400"
SERVICE_NAME="wyoming-onnx-asr-gpu" # New service name to distinguish from CPU

# Environment Variables for GPU deployment
# SET THESE before running!
ONNX_ASR_MODEL="REPLACE_ME_WITH_YOUR_MODEL" # Example: "onnx-community/whisper-large-v3"
ONNX_ASR_LANGUAGE="REPLACE_ME_WITH_YOUR_LANGUAGE" # Example: "en"
ONNX_ASR_PROVIDER="CUDAExecutionProvider"   # Crucial for GPU acceleration

# --- 1. PRE-REQUISITES & SYSTEM SETUP ---
echo "--- Step 1: System setup and checking GPU readiness ---"
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)."
  exit 1
fi

# Basic check for NVIDIA devices inside the LXC
if [ ! -d "/dev/nvidia0" ] && [ ! -d "/dev/nvidiactl" ]; then
    echo "🔥 WARNING: NVIDIA devices not found in /dev/. GPU passthrough may be missing/incorrect."
    read -p "Continue installation anyway? (y/N): " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborting. Please configure GPU passthrough on the Proxmox host first."
        exit 1
    fi
fi

# Install core packages: git, python3, venv + CUDA libraries
apt update && apt install -y git python3 python3-venv

# Install essential CUDA runtime libraries (e.g., for `onnxruntime-gpu` to link against)
# This uses the Debian package for simple installation, relying on the driver from the host.
echo "Installing NVIDIA CUDA runtime libraries..."
apt install -y nvidia-cuda-toolkit libcublas-12-1 libcudnn8

# Create dedicated service user and installation directory
if ! id "${SERVICE_USER}" &>/dev/null; then
    echo "Creating service user: ${SERVICE_USER}"
    useradd --system --no-create-home "${SERVICE_USER}"
fi
mkdir -p "${INSTALL_DIR}"
chown -R "${SERVICE_USER}":"${SERVICE_USER}" "${INSTALL_DIR}"

# --- 2. INSTALLATION ---
echo "--- Step 2: Cloning repository and installing dependencies ---"
git clone "${REPO_URL}" "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Create and populate Python Virtual Environment
sudo -u "${SERVICE_USER}" python3 -m venv .venv
echo "Installing Python dependencies (including onnxruntime-gpu)..."
sudo -u "${SERVICE_USER}" ./.venv/bin/pip install --upgrade pip
# The requirements.txt file in the repo should handle the correct ONNX runtime variant,
# but we ensure it's installed as the service user.
sudo -u "${SERVICE_USER}" ./.venv/bin/pip install --no-cache-dir -r requirements.txt

# --- 3. SYSTEMD SERVICE SETUP ---
echo "--- Step 3: Creating systemd service file ---"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat <<EOF > ${SERVICE_FILE}
[Unit]
Description=Wyoming ONNX ASR Service (GPU)
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
# Expose required GPU-related environment variables
Environment="ONNX_ASR_MODEL=${ONNX_ASR_MODEL}"
Environment="ONNX_ASR_LANGUAGE=${ONNX_ASR_LANGUAGE}"
Environment="ONNX_ASR_PROVIDER=${ONNX_ASR_PROVIDER}"
# The container volume mapping for models is handled automatically by the user's home directory
# and the application's default behavior (~/.local/share/wyoming-onnx-asr)
ExecStart=${INSTALL_DIR}/.venv/bin/wyoming-onnx-asr --uri "tcp://0.0.0.0:${SERVICE_PORT}"
Restart=always
RestartSec=5

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- 4. START SERVICE ---
echo "--- Step 4: Enabling and starting the service ---"
if [[ "${ONNX_ASR_MODEL}" == "REPLACE_ME_WITH_YOUR_MODEL" ]]; then
    echo "⚠️ WARNING: Service file created, but not started. Please configure variables."
else
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl start "${SERVICE_NAME}"
    echo "✅ Success! Service ${SERVICE_NAME} (GPU) is running."
fi
