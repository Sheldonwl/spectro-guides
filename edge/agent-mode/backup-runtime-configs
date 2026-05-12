#!/bin/bash

BACKUP_DIR="/usr/local/backup/container-runtime-configs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"

mkdir -p "${BACKUP_PATH}"

CONFIGS=(
  # containerd
  "/etc/containerd/config.toml"
  "/etc/containerd/conf.d"
  "/etc/containerd/certs.d"

  # k3s / rke2 containerd
  "/var/lib/rancher/k3s/agent/etc/containerd/config.toml"
  "/var/lib/rancher/rke2/agent/etc/containerd/config.toml"

  # crio
  "/etc/crio/crio.conf"
  "/etc/crio/crio.conf.d"
  "/etc/crictl.yaml"

  # docker
  "/etc/docker/daemon.json"

  # podman / containers
  "/etc/containers/storage.conf"
  "/etc/containers/registries.conf"
  "/etc/containers/policy.json"

  # nvidia container runtime
  "/etc/nvidia-container-runtime/config.toml"
  "/etc/nvidia-container-runtime/config"
  "/etc/nvidia-container-toolkit"
  "/usr/share/nvidia-container-toolkit"
  "/usr/share/containers/oci/hooks.d"

  # nvidia CDI
  "/etc/cdi"
  "/var/run/cdi"

  # jetson / IGX specific
  "/etc/nvidia"
  "/etc/nvpmodel.conf"
  "/etc/nv_tegra_release"
  "/etc/systemd/system/nvpmodel.service"
)

FOUND=0

for config in "${CONFIGS[@]}"; do
  if [ -e "${config}" ]; then
    echo "Backing up: ${config}"
    mkdir -p "${BACKUP_PATH}/$(dirname ${config})"
    cp -r "${config}" "${BACKUP_PATH}/${config}"
    FOUND=$((FOUND + 1))
  fi
done

# containerd running with no config - dump defaults
if systemctl is-active --quiet containerd; then
  if [ ! -f "/etc/containerd/config.toml" ]; then
    echo "containerd running with no config file, dumping default config..."
    mkdir -p "${BACKUP_PATH}/etc/containerd"
    containerd config default > "${BACKUP_PATH}/etc/containerd/config.toml.default"
    FOUND=$((FOUND + 1))
  fi
fi

# nvidia runtime info
if command -v nvidia-container-runtime &>/dev/null; then
  echo "Backing up NVIDIA container runtime info..."
  mkdir -p "${BACKUP_PATH}/nvidia-info"
  nvidia-container-runtime --version > "${BACKUP_PATH}/nvidia-info/runtime-version.txt" 2>/dev/null
  nvidia-ctk config dump > "${BACKUP_PATH}/nvidia-info/ctk-config.txt" 2>/dev/null
  nvidia-ctk runtime configure --dry-run > "${BACKUP_PATH}/nvidia-info/ctk-runtime-dry-run.txt" 2>/dev/null
  FOUND=$((FOUND + 1))
fi

# nvidia device info
if command -v nvidia-smi &>/dev/null; then
  echo "Backing up NVIDIA device info..."
  mkdir -p "${BACKUP_PATH}/nvidia-info"
  nvidia-smi > "${BACKUP_PATH}/nvidia-info/nvidia-smi.txt" 2>/dev/null
fi

# docker info
if systemctl is-active --quiet docker; then
  echo "Backing up Docker info..."
  mkdir -p "${BACKUP_PATH}/docker-info"
  docker info > "${BACKUP_PATH}/docker-info/docker-info.txt" 2>/dev/null
  docker system df > "${BACKUP_PATH}/docker-info/docker-system-df.txt" 2>/dev/null
fi

if [ "${FOUND}" -eq 0 ]; then
  echo "No container runtime configs found"
  rmdir "${BACKUP_PATH}"
  exit 1
fi

echo ""
echo "Backed up ${FOUND} items to ${BACKUP_PATH}"
ln -sfn "${BACKUP_PATH}" "${BACKUP_DIR}/latest"
