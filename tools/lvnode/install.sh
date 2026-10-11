#!/usr/bin/env bash
# LocalVPN fleet node installer (docs/RELAY_FLEET.md).
#
# Run as root on a Debian/Ubuntu VPS, with the id and secret shown on the
# admin page (LocalVPN → Fleet → Nodes) right after the node was created:
#
#   sudo bash install.sh --id 3 --secret 'XXXXXXXX' --roles relay,game
#
# Roles: relay (LVR1 relay for members who can't punch), game (WireGuard exit
# that only forwards to game servers), vpn (full WireGuard VPN, Pro).
# Put lvnode-linux-x64 next to this script, or it is downloaded.
# Re-running is safe; --uninstall removes the service.
set -euo pipefail

ID=""
SECRET=""
ROLES="relay"
API="https://xman4289.com/api/v1/localvpn"
BIN_URL="https://xman4289.com/downloads/lvnode/lvnode-linux-x64"
RELAY_PORT=51821
WG_PORT=51820
UNINSTALL=0

die() { echo "install.sh: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) ID="${2:-}"; shift 2 ;;
    --secret) SECRET="${2:-}"; shift 2 ;;
    --roles) ROLES="${2:-}"; shift 2 ;;
    --api) API="${2:-}"; shift 2 ;;
    --binary-url) BIN_URL="${2:-}"; shift 2 ;;
    --relay-port) RELAY_PORT="${2:-}"; shift 2 ;;
    --wg-port) WG_PORT="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run it with sudo"

if (( UNINSTALL )); then
  systemctl disable --now lvnode 2>/dev/null || true
  rm -f /etc/systemd/system/lvnode.service /usr/local/bin/lvnode
  systemctl daemon-reload
  ip link del wg0 2>/dev/null || true
  for chain in LVNODE_FWD LVNODE_IN; do
    iptables -D FORWARD -i wg0 -j LVNODE_FWD 2>/dev/null || true
    iptables -D INPUT -i wg0 -j LVNODE_IN 2>/dev/null || true
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
  done
  echo "lvnode removed (/etc/lvnode.env and /etc/lvnode kept)."
  exit 0
fi

[[ "$ID" =~ ^[0-9]{1,9}$ ]] || die "--id is required (the number on the admin page)"
[[ "$SECRET" =~ ^[A-Za-z0-9._-]{16,128}$ ]] || die "--secret is required (16+ letters/digits)"
[[ "$ROLES" =~ ^(relay|game|vpn)(,(relay|game|vpn))*$ ]] || die "--roles must be relay, game and/or vpn"
[[ "$API" =~ ^https:// ]] || die "--api must be an https URL"
[[ "$RELAY_PORT" =~ ^[0-9]{2,5}$ && "$WG_PORT" =~ ^[0-9]{2,5}$ ]] || die "bad port"

need_exit=0
[[ ",$ROLES," == *",game,"* || ",$ROLES," == *",vpn,"* ]] && need_exit=1

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
packages=(ca-certificates curl iptables)
(( need_exit )) && packages+=(wireguard-tools ipset)
apt-get install -y -qq "${packages[@]}" >/dev/null

echo "==> lvnode binary"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$here/lvnode-linux-x64" ]]; then
  install -m 755 "$here/lvnode-linux-x64" /usr/local/bin/lvnode.new
else
  curl -fsSL "$BIN_URL" -o /usr/local/bin/lvnode.new
  chmod 755 /usr/local/bin/lvnode.new
fi
/usr/local/bin/lvnode.new --version >/dev/null || die "the lvnode binary does not run on this machine"
mv -f /usr/local/bin/lvnode.new /usr/local/bin/lvnode
echo "    lvnode $(/usr/local/bin/lvnode --version)"

install -d -m 700 /etc/lvnode
if (( need_exit )) && [[ ! -s /etc/lvnode/wg.key ]]; then
  echo "==> WireGuard key (stays on this machine)"
  (umask 077 && wg genkey > /etc/lvnode/wg.key)
fi

echo "==> /etc/lvnode.env"
(umask 077 && cat > /etc/lvnode.env <<EOF
LVNODE_ID=$ID
LVNODE_SECRET=$SECRET
LVNODE_ROLES=$ROLES
LVNODE_API=$API
LVNODE_RELAY_PORT=$RELAY_PORT
LVNODE_WG_PORT=$WG_PORT
LVNODE_WG_KEY=/etc/lvnode/wg.key
EOF
)
chmod 600 /etc/lvnode.env

if (( need_exit )); then
  echo "==> IP forwarding"
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-lvnode.conf
  sysctl -q -p /etc/sysctl.d/99-lvnode.conf
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "==> ufw"
  [[ ",$ROLES," == *",relay,"* ]] && ufw allow "$RELAY_PORT/udp" >/dev/null
  (( need_exit )) && ufw allow "$WG_PORT/udp" >/dev/null
fi

echo "==> service"
cat > /etc/systemd/system/lvnode.service <<'EOF'
[Unit]
Description=LocalVPN fleet node (relay / WireGuard exit)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/lvnode.env
ExecStart=/usr/local/bin/lvnode
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable lvnode >/dev/null 2>&1
systemctl restart lvnode
sleep 4
systemctl --no-pager --lines=12 status lvnode || true

cat <<EOF

Done. Check that the node shows "last seen" on the admin page within ~10 s.
If the provider has its own firewall (security group), allow inbound UDP:
EOF
[[ ",$ROLES," == *",relay,"* ]] && echo "  - $RELAY_PORT/udp (relay)"
(( need_exit )) && echo "  - $WG_PORT/udp (WireGuard)"
echo "Logs: journalctl -u lvnode -f"
