#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run as root"
    exit 1
fi

LOGFILE="/var/log/kiosk-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

# === Global Variables ===
DEFAULT_USER="${SUDO_USER:-root}"
CHROMIUM_BIN=""
KIOSK_USER=""
KIOSK_URL=""
AUTOSTART_DIR=""
LXDE_PROFILE=""
AUTOSTART_FILE=""
LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
UDEV_RULES_FILE="/etc/udev/rules.d/99-disable-input.rules"
SERVICE_FILE="/etc/systemd/system/kiosk.service"

# === Functions ===


prompt_user_input() {
    read -p "👤 Enter the username for kiosk session (current: $DEFAULT_USER): " KIOSK_USER
    KIOSK_USER=${KIOSK_USER:-$DEFAULT_USER}
    
    read -p "🌐 Enter the URL to open in kiosk mode (default: https://google.com/): " KIOSK_URL
    KIOSK_URL=${KIOSK_URL:-https://google.com/}
    
    echo "Using username: $KIOSK_USER"
    echo "Using URL: $KIOSK_URL"
}

validate_inputs() {
    if ! id "$KIOSK_USER" &>/dev/null; then
        echo "❌ User $KIOSK_USER does not exist. Please create the user before running this script."
        exit 1
    fi
    
    if [[ -z "$KIOSK_URL" ]]; then
        echo "❌ URL must not be empty. Exiting."
        exit 1
    fi
    
    if ! [[ "$KIOSK_URL" =~ ^https?:// ]]; then
        echo "❌ URL must start with http:// or https://"
        exit 1
    fi
    
    CHROMIUM_BIN=$(command -v chromium || command -v chromium-browser || true)
    if [[ -z "$CHROMIUM_BIN" || ! -x "$CHROMIUM_BIN" ]]; then
        echo "❌ Chromium is not installed or not executable. Exiting."
        exit 1
    fi
}

install_packages() {
    apt update && apt install -y \
    curl \
    chromium \
    lxde-core \
    xinit \
    x11-xserver-utils \
    unclutter \
    openssh-server \
    xinput \
    xserver-xorg \
    xscreensaver \
    lightdm
}

enable_lightdm() {
    systemctl enable lightdm
    
    if systemctl is-enabled lightdm &>/dev/null; then
        echo "✅ LightDM enabled to start on boot."
    else
        echo "❌ Failed to enable LightDM. Please check your system configuration."
    fi
}

enable_ssh() {
    systemctl enable ssh
    systemctl start ssh
}

configure_lightdm_autologin() {
    [[ -f "$LIGHTDM_CONF" ]] && cp "$LIGHTDM_CONF" "$LIGHTDM_CONF.bak.$(date +%F-%T)"
    [[ ! -f "$LIGHTDM_CONF" ]] && touch "$LIGHTDM_CONF"
    
    if ! grep -q "^\[Seat:\*\]" "$LIGHTDM_CONF" 2>/dev/null; then
        echo "[Seat:*]" >> "$LIGHTDM_CONF"
    fi
    
    sed -i '/^autologin-user=/d' "$LIGHTDM_CONF"
    sed -i '/^autologin-user-timeout=/d' "$LIGHTDM_CONF"
    sed -i "/^\[Seat:\*\]/a autologin-user=$KIOSK_USER\nautologin-user-timeout=0" "$LIGHTDM_CONF"
    
}

configure_lxde_autostart() {
    AUTOSTART_DIR="/home/$KIOSK_USER/.config/lxsession"
    LXDE_PROFILE=$(ls "$AUTOSTART_DIR" 2>/dev/null | grep LXDE | head -n 1)
    AUTOSTART_FILE="$AUTOSTART_DIR/$LXDE_PROFILE/autostart"
    
    mkdir -p "$(dirname "$AUTOSTART_FILE")"
    
    cat > "$AUTOSTART_FILE" <<EOF
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
@xscreensaver -no-splash
@xset s off
@xset -dpms
@xset s noblank
@unclutter -idle 0
@$CHROMIUM_BIN --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --incognito $KIOSK_URL
EOF
    
    chown -R "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.config"
}

disable_input_devices() {
    cat > "$UDEV_RULES_FILE" <<EOF
ACTION=="add", SUBSYSTEM=="input", ATTRS{name}=="*Keyboard*", RUN+="/bin/sh -c 'chmod 000 /dev/input/event*'"
ACTION=="add", SUBSYSTEM=="input", ATTRS{name}=="*Mouse*", RUN+="/bin/sh -c 'chmod 000 /dev/input/event*'"
EOF
    
    echo "⚠️  Mouse and keyboard will be disabled by udev rules after reboot. Use SSH to manage the device."
}

create_kiosk_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Kiosk Mode
After=graphical.target

[Service]
User=$KIOSK_USER
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
Environment=DISPLAY=:0
ExecStart=$CHROMIUM_BIN --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --incognito $KIOSK_URL
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF
    
    systemctl daemon-reload
    systemctl enable kiosk.service
}

print_summary_and_reboot() {
    IP_ADDR=$(hostname -I | awk '{print $1}')
    
    echo "🎯 Summary:"
    echo "   Kiosk User:        $KIOSK_USER"
    echo "   URL:               $KIOSK_URL"
    echo "   SSH Access:        ssh $KIOSK_USER@$IP_ADDR"
    echo "   Chromium Binary:   $CHROMIUM_BIN"
    echo "   Log File:          $LOGFILE"
    echo "   Reboot Required:   Yes"
    
    read -p "🔁 Reboot now to apply changes? [y/N]: " REBOOT
    if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
        reboot
    else
        echo "⚠️  Remember to reboot manually to apply kiosk mode."
    fi
}

# === Main Execution ===
install_packages
prompt_user_input
validate_inputs
enable_lightdm
enable_ssh
configure_lightdm_autologin
configure_lxde_autostart
disable_input_devices
create_kiosk_service
print_summary_and_reboot
