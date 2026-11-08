#!/bin/sh
# Auto-detect timezone based on public IP on network up
[ "$2" = "up" ] || exit 0
[ "$1" = "lo" ] && exit 0

(
    sleep 2
    TZ=$(curl -s --max-time 5 "http://ip-api.com/line?fields=timezone" 2>/dev/null | tr -d "\r\n")
    if [ -n "$TZ" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
        CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
        if [ "$TZ" != "$CURRENT_TZ" ]; then
            timedatectl set-timezone "$TZ"
            logger -t auto-timezone "Updated timezone from $CURRENT_TZ to $TZ"
            systemctl try-restart thinksmart-kiosk thinksmart-client 2>/dev/null || true
        fi
    fi
) &
