#!/bin/bash

DEVICE="/dev/input/event0"
KEY_CODE="106"
LIMIT=5
WINDOW=1
LOCK_FILE="/tmp/arrow_disabled"
LOG_FILE="/tmp/arrow_presses.log"

X_KEYCODE=$(xmodmap -pke | grep "Right" | awk '{print $2}' | head -n 1)
[ -z "$X_KEYCODE" ] && X_KEYCODE=114

if [ "$1" == "--daemon" ]; then
    cat /dev/null > "$LOG_FILE"
    
    sudo stdbuf -o0 evtest "$DEVICE" 2>/dev/null | while read -r line; do
        if [ -f "$LOCK_FILE" ]; then
            continue
        fi

        if echo "$line" | grep -qE "code $KEY_CODE \(KEY_RIGHT\), value [12]"; then
            current_time=$(date +%s)
            echo "$current_time" >> "$LOG_FILE"

            threshold=$((current_time - WINDOW))
            count=$(awk -v t="$threshold" '$1 > t' "$LOG_FILE" | wc -l)

            if [ "$count" -gt "$LIMIT" ]; then
                touch "$LOCK_FILE"
                cat /dev/null > "$LOG_FILE"
                xmodmap -e "keycode $X_KEYCODE = NoSymbol"
            fi
        fi
    done
    exit 0
fi

if [ "$1" == "--release" ]; then
    xmodmap -e "keycode $X_KEYCODE = Right"
    rm -f "$LOCK_FILE" "$LOG_FILE"
    exit 0
fi

SERVICE_FILE="/etc/systemd/system/anti_flood.service"

sudo sh -c "cat << 'EOF' > $SERVICE_FILE
[Unit]
Description=Anti Flood Key Daemon
After=multi-user.target

[Service]
Type=simple
ExecStart=/home/yassine/bash-tools/anti_flood.sh --daemon
Restart=always
Env=DISPLAY=:0
Env=XAUTHORITY=/home/yassine/.Xauthority

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable anti_flood.service
sudo systemctl restart anti_flood.service
