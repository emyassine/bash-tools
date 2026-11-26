#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)."
    exit 1
fi

echo "Updating package lists..."
apt-get update

echo "Checking and installing dependencies..."
apt-get install -y uhubctl jq

TOGGLE_SCRIPT="/usr/local/bin/keyboard-toggle.sh"
echo "Creating toggle script at $TOGGLE_SCRIPT..."

cat << 'EOF' > "$TOGGLE_SCRIPT"
#!/bin/bash

echo "Executing hardware check..."

BUILTIN_DEV=$(find /sys/class/input/ -name "input*" | while read -r dev; do
    if [ -f "$dev/name" ]; then
        name=$(cat "$dev/name")
        if [[ "$name" == *"AT Translated Set 2 keyboard"* || "$name" == *"at translated set 2 keyboard"* ]]; then
            basename "$dev"
            break
        fi
    fi
done)

if [ -z "$BUILTIN_DEV" ]; then
    BUILTIN_DEV=$(find /sys/class/input/ -name "input*" | while read -r dev; do
        if [ -f "$dev/name" ]; then
            name=$(cat "$dev/name")
            if [[ "$name" == *"keyboard"* || "$name" == *"Keyboard"* ]] && [[ "$name" != *"USB"* && "$name" != *"usb"* && "$name" != *"Wireless"* && "$name" != *"Virtual"* ]]; then
                basename "$dev"
                break
            fi
        fi
    done)
fi

if [ -z "$BUILTIN_DEV" ]; then
    echo "Error: No builtin keyboard identified in sysfs."
    exit 1
fi

echo "Identified core builtin device: $BUILTIN_DEV"

EXTERNAL_FOUND=0
while read -r name_file; do
    [ -f "$name_file" ] || continue
    name=$(cat "$name_file")
    if [[ "$name" == *"Keyboard"* || "$name" == *"keyboard"* ]]; then
        if [[ "$name" != *"AT Translated Set 2"* && "$name" != *"at translated set 2"* ]]; then
            echo "External keyboard detected: $name"
            EXTERNAL_FOUND=1
            break
        fi
    fi
done < <(find /sys/class/input/input*/name)

if [ "$EXTERNAL_FOUND" -eq 1 ]; then
    echo "Inhibiting builtin keyboard ($BUILTIN_DEV)..."
    echo "1" > "/sys/class/input/$BUILTIN_DEV/inhibited"
else
    echo "Restoring builtin keyboard ($BUILTIN_DEV)..."
    echo "0" > "/sys/class/input/$BUILTIN_DEV/inhibited"
fi
EOF

echo "Setting executable permissions on $TOGGLE_SCRIPT..."
chmod +x "$TOGGLE_SCRIPT"

UDEV_RULE="/etc/udev/rules.d/99-keyboard-toggle.rules"
echo "Generating udev rule at $UDEV_RULE..."
mkdir -p /etc/udev/rules.d
echo 'ACTION=="add", SUBSYSTEM=="input", RUN+="/usr/local/bin/keyboard-toggle.sh"' > "$UDEV_RULE"
echo 'ACTION=="remove", SUBSYSTEM=="input", RUN+="/usr/local/bin/keyboard-toggle.sh"' >> "$UDEV_RULE"

echo "Reloading udev rules..."
udevadm control --reload-rules

echo "Triggering initial udev event process..."
udevadm trigger

echo "Running initial hardware sync..."
$TOGGLE_SCRIPT

echo "Deployment complete successfully."
