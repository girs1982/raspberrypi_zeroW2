#!/bin/bash
# The script configures simultaneous AP and Managed Mode Wifi on Raspberry Pi Zero W
# Исправленная версия с использованием интерфейса ap@wlan0
# Licence: GPLv3

sudo apt-get install ifupdown -y
sudo apt-get install iptables -y

# Error management
set -o errexit
set -o pipefail
set -o nounset

usage() {
    cat 1>&2 <<EOF
Configures simultaneous AP and Managed Mode Wifi on Raspberry Pi

USAGE:
    rpi-wifi -a <ap_ssid> [<ap_password>] -c <client_ssid> [<client_password>]
    
    rpi-wifi -a MyAP myappass -c MyWifiSSID mywifipass

PARAMETERS:
    -a, --ap          AP SSID & password
    -c, --client      Client SSID & password
    -i, --ip          AP IP

FLAGS:
    -n, --no-internet Disable IP forwarding
    -h, --help        Show this help
EOF
    exit 0
}

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -c|--client)
    CLIENT_SSID="$2"
    CLIENT_PASSPHRASE="$3"
    shift
    shift
    shift
    ;;
    -a|--ap)
    AP_SSID="$2"
    AP_PASSPHRASE="$3"
    shift
    shift
    shift
    ;;
    -i|--ip)
    ARG_AP_IP="$2"
    shift
    shift
    ;;
    -h|--help)
    usage
    shift
    ;;
    -n|--no-internet)
    NO_INTERNET="true"
    shift
    ;;
    *)
    POSITIONAL+=("$1")
    shift
    ;;
esac
done
set -- "${POSITIONAL[@]}"

[ -n "${AP_SSID-}" ] || usage

AP_IP=${ARG_AP_IP:-'192.168.10.1'}
AP_IP_BEGIN=$(echo "${AP_IP}" | sed -e 's/\.[0-9]\{1,3\}$//g')
MAC_ADDRESS="$(cat /sys/class/net/wlan0/address)"

# Install dependencies
sudo apt -y update
sudo apt -y upgrade
sudo apt -y install dnsmasq dhcpcd hostapd cron

# udev rules для создания виртуального интерфейса
sudo bash -c 'cat > /etc/udev/rules.d/70-persistent-net.rules' << EOF
SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="${MAC_ADDRESS}", KERNEL=="phy0", \\
  RUN+="/sbin/iw phy phy0 interface add ap@wlan0 type __ap", \\
  RUN+="/bin/ip link set ap@wlan0 address ${MAC_ADDRESS}"
EOF

# dnsmasq config
sudo bash -c 'cat > /etc/dnsmasq.conf' << EOF
interface=lo,ap@wlan0
no-dhcp-interface=lo,ap@wlan0
bind-interfaces
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=${AP_IP_BEGIN}.50,${AP_IP_BEGIN}.150,12h
EOF

# hostapd config
sudo bash -c 'cat > /etc/hostapd/hostapd.conf' << EOF
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
interface=ap@wlan0
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
wpa=2
$([ -n "${AP_PASSPHRASE-}" ] && echo "wpa_passphrase=${AP_PASSPHRASE}")
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
EOF

# hostapd default config
sudo bash -c 'cat > /etc/default/hostapd' << EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# wpa_supplicant config
sudo bash -c 'cat > /etc/wpa_supplicant/wpa_supplicant.conf' << EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${CLIENT_SSID}"
    $([ -n "${CLIENT_PASSPHRASE-}" ] && echo "psk=\"${CLIENT_PASSPHRASE}\"")
    scan_ssid=1
    key_mgmt=WPA-PSK
    id_str="AP1"
}
EOF

# network interfaces
sudo bash -c 'cat > /etc/network/interfaces' << EOF
source-directory /etc/network/interfaces.d

auto lo
auto ap@wlan0
auto wlan0

iface lo inet loopback

# AP configuration
allow-hotplug ap@wlan0
iface ap@wlan0 inet static
    address ${AP_IP}
    netmask 255.255.255.0
    hostapd /etc/hostapd/hostapd.conf

# Client configuration
allow-hotplug wlan0
iface wlan0 inet manual
    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf

iface AP1 inet dhcp
EOF

# Startup script
sudo bash -c 'cat > /bin/rpi-wifi.sh' << EOF
#!/bin/bash
echo 'Starting Wifi AP and client...'
sleep 30

# Включение виртуального интерфейса
sudo ip link set ap@wlan0 up

# Сброс клиентского интерфейса
sudo rm -f /var/run/wpa_supplicant/wlan0
sudo ifdown --force wlan0
sudo ifup wlan0

# Настройка маршрутизации
$([ "${NO_INTERNET-}" != "true" ] && echo "sudo sysctl -w net.ipv4.ip_forward=1")
$([ "${NO_INTERNET-}" != "true" ] && echo "sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE")
$([ "${NO_INTERNET-}" != "true" ] && echo "sudo iptables -A FORWARD -i ap@wlan0 -o wlan0 -j ACCEPT")

# Перезапуск сервисов
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq
EOF

sudo chmod +x /bin/rpi-wifi.sh

# Cron job
(sudo crontab -l 2>/dev/null; echo "@reboot /bin/rpi-wifi.sh") | sudo crontab -

echo "Configuration complete! Reboot to apply changes."
