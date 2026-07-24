#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a MicroK8s worker node from the control plane
# Usage: ./bootstrap-worker.sh <worker-ip> [ssh-user]
#
# Runs on the control plane node. SSHes to the worker to install
# snap/microk8s, joins it to the cluster, configures flannel CIDR
# (10.69.XX.0/24), and verifies connectivity.

# Source SSH agent if available
if [ -f "${HOME}/.ssh/agent-env" ]; then
    source "${HOME}/.ssh/agent-env"
fi

WORKER_IP="${1:?Usage: $0 <worker-ip> [ssh-user]}"
SSH_USER="${2:-$(whoami)}"
MICROK8S_CHANNEL="latest/stable"
CIDR_PREFIX="10.69"
CIDR_MASK="/24"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=20"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
err() { log "ERROR: $*" >&2; exit 1; }
ssh_worker() { ssh ${SSH_OPTS} "${SSH_USER}@${WORKER_IP}" "$@"; }

# --- Pre-flight checks ---
log "Verifying control plane microk8s is running..."
microk8s status --wait-ready >/dev/null 2>&1 || err "microk8s is not running on this control plane"

log "Checking SSH connectivity to ${SSH_USER}@${WORKER_IP}..."
ssh_worker "echo ok" >/dev/null 2>&1 || err "Cannot SSH to ${SSH_USER}@${WORKER_IP}"

# --- Determine next available CIDR ---
log "Discovering next available flannel CIDR..."

# Get existing pod CIDRs from all nodes (3rd octet)
USED_OCTETS=$(microk8s kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null \
    | grep "^${CIDR_PREFIX}\." \
    | awk -F. '{print $3}' \
    | sort -n)

# Find the next available 3rd octet (continues from the highest in use)
MAX_OCTET=0
for octet in ${USED_OCTETS}; do
    if [ "${octet}" -gt "${MAX_OCTET}" ]; then
        MAX_OCTET="${octet}"
    fi
done
NEXT_OCTET=$((MAX_OCTET + 1))

if [ "${NEXT_OCTET}" -gt 254 ]; then
    err "No available CIDR octets left in ${CIDR_PREFIX}.X.0${CIDR_MASK}"
fi

NODE_CIDR="${CIDR_PREFIX}.${NEXT_OCTET}.0${CIDR_MASK}"
NODE_CIDR_IP="${CIDR_PREFIX}.${NEXT_OCTET}.0"
log "Allocated CIDR: ${NODE_CIDR}"

# --- Fix cgroups if needed (Raspberry Pi) ---
log "Checking cgroup configuration on worker..."
NEEDS_REBOOT=false
if ! ssh_worker "grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null"; then
    log "Fixing cgroup memory controller (not available)..."
    ssh_worker "sudo bash -s" <<'CGROUP_EOF'
set -euo pipefail
CMDLINE_FILE=""
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [ -f "$f" ] && CMDLINE_FILE="$f" && break
done
if [ -z "$CMDLINE_FILE" ]; then
    echo "ERROR: Cannot find cmdline.txt" >&2
    exit 1
fi
# Add cgroup_enable=memory cgroup_memory=1 if not already present
if ! grep -q "cgroup_enable=memory" "$CMDLINE_FILE"; then
    sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE_FILE"
    echo "Updated $CMDLINE_FILE"
fi
CGROUP_EOF
    NEEDS_REBOOT=true
fi

if [ "${NEEDS_REBOOT}" = true ]; then
    log "Rebooting worker to apply cgroup fix..."
    ssh_worker "sudo reboot" || true
    sleep 15
    # Wait for worker to come back
    for i in $(seq 1 60); do
        if ssh_worker "echo ok" &>/dev/null; then
            break
        fi
        sleep 5
    done
    ssh_worker "echo ok" >/dev/null 2>&1 || err "Worker did not come back after reboot"
    log "Worker is back online"
    # Verify fix applied
    if ! ssh_worker "grep -q memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null"; then
        err "cgroup memory controller still not available after reboot"
    fi
    log "cgroup memory controller is now enabled"
fi

# --- Install snap and microk8s on worker ---
log "Installing snap and microk8s on worker ${WORKER_IP}..."
ssh_worker "sudo bash -s" <<INSTALL_EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/snap/bin:\$PATH"

# Install snapd if not present
if ! command -v snap &>/dev/null; then
    echo "Installing snapd..."
    apt-get update -qq
    apt-get install -y -qq snapd
    systemctl enable --now snapd.socket
    sleep 5
    snap wait system seed.loaded
fi

# Install microk8s if not present
if ! snap list microk8s &>/dev/null; then
    echo "Installing microk8s ${MICROK8S_CHANNEL}..."
    snap install microk8s --classic --channel=${MICROK8S_CHANNEL}
else
    echo "microk8s already installed"
fi

echo "Starting microk8s..."
microk8s start
echo "Waiting for microk8s to be ready..."
microk8s status --wait-ready --timeout 300
INSTALL_EOF

# --- Fix resolv.conf for kubelet (systems without systemd-resolved) ---
log "Checking DNS resolver configuration on worker..."
ssh_worker "sudo bash -s" <<'RESOLV_EOF'

# STUFF that cluade miss
sudo apt update
sudo apt install -y systemd-resolved


set -euo pipefail
KUBELET_ARGS="/var/snap/microk8s/current/args/kubelet"

# If systemd-resolved is active, /run/systemd/resolve/resolv.conf will exist — nothing to do
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "systemd-resolved is active, DNS config OK"
    exit 0
fi

# No systemd-resolved: patch kubelet args to use /etc/resolv.conf directly (permanent, survives reboots)
if grep -q '/run/systemd/resolve/resolv.conf' "${KUBELET_ARGS}" 2>/dev/null; then
    sed -i 's|/run/systemd/resolve/resolv.conf|/etc/resolv.conf|g' "${KUBELET_ARGS}"
    echo "Patched kubelet args to use /etc/resolv.conf"
    snap stop microk8s
    snap start microk8s
else
    echo "kubelet already uses /etc/resolv.conf or no systemd resolv.conf reference — no patch needed"
fi
RESOLV_EOF

# --- Remove conflicting CNI configs (microk8s v1.35+ ships calico by default) ---
log "Ensuring only flannel CNI is configured on worker..."
ssh_worker "sudo rm -f /var/snap/microk8s/current/args/cni-network/10-calico.conflist /var/snap/microk8s/current/args/cni-network/calico-kubeconfig 2>/dev/null || true"

# Add SSH user to microk8s group
ssh_worker "sudo usermod -aG microk8s ${SSH_USER} 2>/dev/null || true"

# --- Leave any existing cluster before joining ---
log "Checking if worker is already in a cluster..."
# THIS IS BROKEN:
WORKER_DS=$(ssh_worker "sudo /snap/bin/microk8s status 2>/dev/null" | grep "datastore master nodes:" | awk '{print $NF}' || echo "")
if [ -n "${WORKER_DS}" ] && [ "${WORKER_DS}" != "127.0.0.1:19001" ]; then
    log "Worker is already in a cluster (${WORKER_DS}), checking if it's ours..."
    # Already in our cluster — skip join
    ALREADY_JOINED=true
else
    ALREADY_JOINED=false
    if [ -n "${WORKER_DS}" ] && [ "${WORKER_DS}" = "127.0.0.1:19001" ]; then
        log "Worker is running standalone microk8s, will leave before joining..."
        ssh_worker "sudo /snap/bin/microk8s leave" || true
    fi
fi

if [ "${ALREADY_JOINED}" = false ]; then
    # --- Generate join token and join worker ---
    log "Generating join token on control plane..."
    JOIN_URL=$(microk8s add-node --format short 2>/dev/null | head -1 | awk '{print $NF}')

    if [ -z "${JOIN_URL}" ]; then
        err "Failed to generate join token"
    fi

    log "Joining worker to cluster with: ${JOIN_URL}"
    ssh_worker "sudo /snap/bin/microk8s join ${JOIN_URL} --worker"
fi

# --- Wait for node to appear ---
log "Waiting for worker node to appear in cluster..."
WORKER_HOSTNAME=$(ssh_worker "hostname")
for i in $(seq 1 30); do
    if microk8s kubectl get node "${WORKER_HOSTNAME}" &>/dev/null; then
        break
    fi
    sleep 2
done
microk8s kubectl get node "${WORKER_HOSTNAME}" &>/dev/null || err "Worker node ${WORKER_HOSTNAME} did not appear in cluster"

# --- Configure flannel CIDR on the node ---
log "Configuring flannel podCIDR ${NODE_CIDR} on node ${WORKER_HOSTNAME}..."

# Patch the node spec with the allocated podCIDR
microk8s kubectl patch node "${WORKER_HOSTNAME}" --type merge -p "{\"spec\":{\"podCIDR\":\"${NODE_CIDR}\"}}"

# Wait for node to become Ready
log "Waiting for node to become Ready..."
microk8s kubectl wait --for=condition=Ready "node/${WORKER_HOSTNAME}" --timeout=120s

log "Node ${WORKER_HOSTNAME} is Ready with podCIDR ${NODE_CIDR}"

# --- Verify flannel and pod connectivity ---
log "Verifying flannel CIDR connectivity..."

# Check that the flannel interface has the right CIDR on the worker
sleep 5  # give flannel a moment to configure the interface
FLANNEL_IP=$(ssh_worker "ip -4 addr show flannel.1 2>/dev/null | grep -oP 'inet \K[0-9.]+'") || true

if [ -n "${FLANNEL_IP}" ]; then
    log "Worker flannel.1 interface IP: ${FLANNEL_IP}"
else
    log "WARN: flannel.1 interface not yet visible, it may take a moment to configure"
fi

# Ping test from worker to its own CIDR gateway
log "Testing CIDR IP reachability from worker..."
if ssh_worker "ping -c 2 -W 3 ${NODE_CIDR_IP}" &>/dev/null; then
    log "PASS: Worker can ping ${NODE_CIDR_IP}"
else
    log "WARN: Worker cannot ping ${NODE_CIDR_IP} yet — flannel may still be converging"
fi

# --- Verify pod scheduling on the worker ---
log "Verifying pods can be scheduled on worker..."
TEST_POD="bootstrap-test-${WORKER_HOSTNAME}"

microk8s kubectl run "${TEST_POD}" \
    --image=busybox \
    --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"${WORKER_HOSTNAME}\"}}" \
    -- sleep 30

log "Waiting for test pod to start on worker..."
if microk8s kubectl wait --for=condition=Ready "pod/${TEST_POD}" --timeout=90s 2>/dev/null; then
    POD_IP=$(microk8s kubectl get pod "${TEST_POD}" -o jsonpath='{.status.podIP}')
    log "PASS: Test pod running on ${WORKER_HOSTNAME} with IP ${POD_IP}"

    # Verify the pod IP is within the allocated CIDR
    POD_THIRD_OCTET=$(echo "${POD_IP}" | awk -F. '{print $3}')
    if [ "${POD_THIRD_OCTET}" = "${NEXT_OCTET}" ]; then
        log "PASS: Pod IP ${POD_IP} is within allocated CIDR ${NODE_CIDR}"
    else
        log "WARN: Pod IP ${POD_IP} is NOT within expected CIDR ${NODE_CIDR}"
    fi
else
    log "WARN: Test pod did not become Ready within timeout"
fi

# Cleanup test pod
microk8s kubectl delete pod "${TEST_POD}" --ignore-not-found &>/dev/null &

# --- Summary ---
echo ""
log "========================================="
log "Worker bootstrap complete!"
log "  Worker:   ${WORKER_HOSTNAME} (${WORKER_IP})"
log "  podCIDR:  ${NODE_CIDR}"
log "  Status:   $(microk8s kubectl get node ${WORKER_HOSTNAME} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
log "========================================="
