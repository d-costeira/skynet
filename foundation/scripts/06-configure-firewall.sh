#!/usr/bin/env bash
# Step 6: host security baseline.
#   - SSH: keys only, no root login.
#   - UFW: deny all inbound except SSH from the trusted LAN.
#   - DOCKER-USER: containers can't open new outbound connections.
#
# Nothing in foundation/inference publishes a port on the LAN (LiteLLM is bound
# to 127.0.0.1), so SSH is the only service other machines can reach.
source "$(dirname "$0")/common.sh"
require_root

user="${SUDO_USER:-}"
[[ -n "${user}" ]] || die "Run via sudo from your normal account, so the SSH key check can find your keys."

log "Pre-flight checks (to avoid locking you out)"

auth_keys="$(getent passwd "${user}" | cut -d: -f6)/.ssh/authorized_keys"
if [[ ! -s "${auth_keys}" ]]; then
  die "${auth_keys} is missing or empty. Add your SSH public key first (ssh-copy-id ${user}@${SKYNET_IP}), test a key login, then re-run."
fi
echo "OK: ${user} has $(grep -c -E '^(ssh-|ecdsa-|sk-)' "${auth_keys}") SSH key(s)."

if [[ -n "${SSH_CLIENT:-}" ]]; then
  client_ip="${SSH_CLIENT%% *}"
  if python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('${client_ip}') in ipaddress.ip_network('${LAN_SUBNET}') else 1)"; then
    echo "OK: your SSH session comes from ${client_ip}, inside ${LAN_SUBNET}."
  else
    die "Your SSH session comes from ${client_ip}, which is OUTSIDE LAN_SUBNET=${LAN_SUBNET}. Fix LAN_SUBNET in foundation/skynet.conf first."
  fi
fi

echo
echo "This will:"
echo "  - disable SSH password logins and root login"
echo "  - allow inbound SSH only from ${LAN_SUBNET}, deny all other inbound"
echo "  - block containers on 172.30.0.0/24 from opening outbound connections"
confirm "Apply?" || exit 1

log "Hardening SSH"
cat > /etc/ssh/sshd_config.d/10-skynet.conf <<'EOF'
# Managed by skynet/foundation/scripts/06-configure-firewall.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sshd -t
systemctl reload ssh

log "Configuring UFW"
apt-get install -y ufw
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow from "${LAN_SUBNET}" to any port 22 proto tcp comment 'SSH from trusted LAN'
ufw --force enable
ufw status verbose

log "Installing the container egress block"
install -m 0755 "${FOUNDATION_DIR}/scripts/docker-egress-block" /usr/local/sbin/docker-egress-block
install -m 0644 "${FOUNDATION_DIR}/systemd/docker-egress-block.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now docker-egress-block.service
iptables -S DOCKER-USER

echo
warn "Keep this SSH session open and test a NEW ssh login from another terminal before logging out."
