#!/bin/bash
set -x
[ $(id -u) -eq 0 ] || exec sudo $0 $@

# Load custom environment variables from /etc/spectro/environment if it exists
if [ -f /etc/spectro/environment ]; then
    . /etc/spectro/environment
fi

function uninstall_systemd_service() {
    local service_name=$1
    if command -v systemctl; then
        systemctl stop ${service_name}
        systemctl disable ${service_name}
        systemctl daemon-reload
    fi
}

for service in $(ls /etc/systemd/system/spectro*); do
    uninstall_systemd_service $(basename ${service})
done

for service in $(ls /run/systemd/system/spectro*); do
    uninstall_systemd_service $(basename ${service})
done

if [ ! -f ${STYLUS_ROOT}/opt/spectrocloud/state/registration ]; then
    ${STYLUS_ROOT}/opt/spectrocloud/bin/palette-agent reset
fi

rm -f /etc/spectro/environment
rm -f /run/systemd/system/spectro*
rm -f /etc/systemd/system/spectro*
rm -rf /run/stylus
rm -rf /etc/default/kubelet
rm -rf /usr/bin/kubelet
rm -rf /usr/bin/kubectl
rm -rf /usr/bin/kubeadm
rm -rf /opt/kubeadm
rm -rf /opt/bin/
rm -rf /usr/local/bin/kubelet
rm -rf /opt/sentinel_kubeadmversion
rm -rf /opt/kube-images
rm -rf /opt/kube-images
rm -rf /opt/kubeadm.join
rm -rf /opt/containerd
rm -rf /opt/cni

function remove_stylus_root() {
    rm -rf ${STYLUS_ROOT}/opt/spectrocloud
    rm -rf ${STYLUS_ROOT}/usr/local/spectrocloud
    rm -rf ${STYLUS_ROOT}/usr/local/stylus
    rm -rf ${STYLUS_ROOT}/etc/spectro
    rm -rf ${STYLUS_ROOT}/oem
    rm -rf ${STYLUS_ROOT}/system/oem
}
trap remove_stylus_root EXIT