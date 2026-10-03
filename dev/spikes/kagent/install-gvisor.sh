#!/bin/bash
# Installs gVisor (runsc) as a containerd runtime handler named "runsc". Run as root on each worker.
# gVisor's default systrap platform needs no KVM, so this works on Firecracker-backed playgrounds.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" > /etc/apt/sources.list.d/gvisor.list
apt-get update -qq >/dev/null && apt-get install -y -qq runsc >/dev/null
if ! grep -q 'runtimes.runsc' /etc/containerd/config.toml; then
  cat >> /etc/containerd/config.toml <<'TOML'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
TOML
fi
systemctl restart containerd
runsc --version | head -1
