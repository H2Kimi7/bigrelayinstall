#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="138.252.163.253"
PORT_RANGE="1000:65535"
SERVICE_NAME="jc-monitor.service"
FORWARD_SCRIPT="/usr/local/bin/jc-net-forward.sh"
MONITOR_SCRIPT="/usr/local/bin/monitor.sh"
JC_CMD="/usr/local/bin/jc"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash install_jc.sh"
  exit 1
fi

if [[ ! -r /etc/debian_version ]]; then
  echo "This installer supports Debian/Ubuntu style systems only."
  exit 1
fi

if [[ ! -f "./monitor.sh" ]]; then
  echo "monitor.sh not found in current directory: $(pwd)"
  exit 1
fi

DEFAULT_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [[ -z "${DEFAULT_IFACE}" ]]; then
  echo "Unable to detect default network interface."
  exit 1
fi

LOCAL_IP="$(ip -4 addr show dev "${DEFAULT_IFACE}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
if [[ -z "${LOCAL_IP}" ]]; then
  echo "Unable to detect IPv4 address on ${DEFAULT_IFACE}."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y iptables iptables-persistent netfilter-persistent

cat > "${FORWARD_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="${TARGET_IP}"
PORT_RANGE="${PORT_RANGE}"

DEFAULT_IFACE="\$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"dev\"){print \$(i+1); exit}}')"
if [[ -z "\${DEFAULT_IFACE}" ]]; then
  echo "Unable to detect default interface."
  exit 1
fi

LOCAL_IP="\$(ip -4 addr show dev "\${DEFAULT_IFACE}" | awk '/inet /{print \$2}' | cut -d/ -f1 | head -n1)"
if [[ -z "\${LOCAL_IP}" ]]; then
  echo "Unable to detect local IPv4 on \${DEFAULT_IFACE}."
  exit 1
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null

ensure_rule() {
  local table="\$1"
  shift
  if ! iptables -t "\$table" -C "\$@" 2>/dev/null; then
    iptables -t "\$table" -A "\$@"
  fi
}

ensure_rule nat PREROUTING -p tcp -d "\${TARGET_IP}" --dport "\${PORT_RANGE}" -j DNAT --to-destination "\${LOCAL_IP}"
ensure_rule nat PREROUTING -p udp -d "\${TARGET_IP}" --dport "\${PORT_RANGE}" -j DNAT --to-destination "\${LOCAL_IP}"

ensure_rule filter FORWARD -p tcp -d "\${LOCAL_IP}" --dport "\${PORT_RANGE}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
ensure_rule filter FORWARD -p udp -d "\${LOCAL_IP}" --dport "\${PORT_RANGE}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
ensure_rule filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables-save > /etc/iptables/rules.v4
netfilter-persistent save >/dev/null

echo "Forwarding ready: \${TARGET_IP}:\${PORT_RANGE} -> \${LOCAL_IP}:\${PORT_RANGE}"
EOF

chmod +x "${FORWARD_SCRIPT}"

cp ./monitor.sh "${MONITOR_SCRIPT}"
chmod +x "${MONITOR_SCRIPT}"

cat > /etc/systemd/system/${SERVICE_NAME} <<'EOF'
[Unit]
Description=JC Monitor Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monitor.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > "${JC_CMD}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo /usr/local/bin/jc "$@"
fi

exec /usr/local/bin/monitor.sh "$@"
EOF

chmod +x "${JC_CMD}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
if grep -q '^net.ipv4.ip_forward=' /etc/sysctl.conf; then
  sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}" >/dev/null

"${FORWARD_SCRIPT}"

echo
echo "Install completed."
echo "Detected interface: ${DEFAULT_IFACE}"
echo "Detected local IP: ${LOCAL_IP}"
echo "Type 'jc' in terminal to re-apply forwarding and restart monitor service."
