#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

echo "==> Installing incron..."
apt-get update -qq
apt-get install -y -qq incron

echo "==> Allowing incron for root..."
echo "root" >> /etc/incron.allow 2>/dev/null || true

echo "==> Setting up incrontab to watch /etc/wireguard/..."
INCROMON_SCRIPT="/usr/local/bin/wg-auto-up.sh"

cat > "$INCROMON_SCRIPT" << 'SCRIPT'
#!/bin/bash
conf="$1"
if [[ "$conf" == *.conf ]] && [[ -f "/etc/wireguard/$conf" ]]; then
  iface="${conf%.conf}"
  if wg show "$iface" &>/dev/null; then
    echo "[wg-auto-up] $iface already up, skipping"
  else
    echo "[wg-auto-up] Bringing up $iface..."
    wg-quick up "$iface"
  fi
fi
SCRIPT

chmod +x "$INCROMON_SCRIPT"

echo "/etc/wireguard/ IN_CLOSE_WRITE $INCROMON_SCRIPT \$#" | incrontab -

echo "==> Restarting incron..."
systemctl restart incron
systemctl enable incron

echo "==> Done. Place .conf files in /etc/wireguard/ and they will auto-connect."
echo "    Use: nano /etc/wireguard/wg0.conf"
