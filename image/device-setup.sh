#!/bin/sh
# Turn a running ThinkSmart (the old Plasma-based image plus our services) into the release layout.
# Run on the device as root from a copy of this repository:
#   sudo sh image/device-setup.sh files            system-layer files from this tree (kiosk, screen, mic, zram)
#   sudo sh image/device-setup.sh update CLIENT    updater; CLIENT (a client tree with .venv) becomes
#                                                  /opt/thinksmart/client/<version>
#   sudo sh image/device-setup.sh kiosk            boot into the kiosk through thinksmart-kiosk.service, not SDDM
#   sudo sh image/device-setup.sh purge [-n]       remove Plasma/KWin/SDDM/Qt and other unused packages
#                                                  (-n: only show what apt would do)
#   sudo sh image/device-setup.sh tidy             persistent journal, time zone, leftovers of earlier experiments
#   sudo sh image/device-setup.sh codec            the DMIC clock fix: codec-dmic/out/ (codec-dmic/build.sh)
#                                                  module into /lib/modules and DTB into /boot (writes the boot
#                                                  partition: ask the owner first), checked against expected.md5
#   sudo sh image/device-setup.sh camera           the front camera: camera/out/ (camera/build.sh,
#                                                  camera/build-libcamera.sh) sensor and v4l2loopback modules,
#                                                  the DTB with the DMIC fix and the camera nodes into /boot
#                                                  (writes the boot partition: ask the owner first; run after
#                                                  codec), libcamera package, /dev/video10 webcam service
#   sudo sh image/device-setup.sh hold             keep the packages in image/held-packages.txt at their tested
#                                                  versions (apt-mark hold); the kernel isn't a package
#   sudo sh image/device-setup.sh alsa-plugin DEB  PipeWire's ALSA plugin taken out of Ubuntu's pipewire-alsa
#                                                  1.0.5 .deb (apt can't install it next to neon's pipewire 1.2)
# Each step can be run again. Reboot after kiosk, purge, codec and camera and check the screen,
# the sound and the camera.
set -e
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U=ubuntu
H=/home/$U
UCONF=$H/.config/systemd/user

user_systemctl() { runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user "$@"; }

files() {
    install -m 755 kiosk/thinksmart-kiosk.py kiosk/thinksmart-kiosk-session kiosk/thinksmart-kiosk-app \
        kiosk/kiosk-mode kiosk/gpu-watchdog.py screen/idle-blanker.py screen/screen-wake-daemon.py \
        screen/vcnl4200-proximity-daemon.py xiaozhi/thinksmart-mic /usr/local/bin/
    install -d /usr/local/share/thinksmart-kiosk
    install -m 644 kiosk/welcome.html kiosk/keyboard.js kiosk/qrcode.js /usr/local/share/thinksmart-kiosk/
    [ -e /etc/thinksmart-kiosk.conf ] || install -m 644 kiosk/thinksmart-kiosk.conf /etc/
    install -m 644 kiosk/thinksmart-gpu-watchdog.service screen/screen-wake.service \
        zram/thinksmart-zram.service image/thinksmart-ssh-hostkeys.service /etc/systemd/system/
    install -m 644 zram/99-zram.conf /etc/sysctl.d/
    install -m 644 xiaozhi/asound.conf /etc/asound.conf
    install -d -o $U -g $U $UCONF $H/.config/pipewire/pipewire.conf.d
    install -m 644 -o $U -g $U screen/idle-blanker.service xiaozhi/thinksmart-mic.service $UCONF/
    install -m 644 -o $U -g $U xiaozhi/10-thinksmart-rate.conf $H/.config/pipewire/pipewire.conf.d/
    # Speaker S16LE and PipeWire kept off the DSP capture PCM. WirePlumber loads only the
    # highest-priority file of a name, so the user copy decides; the system copy is kept equal
    install -d -o $U -g $U $H/.config/wireplumber $H/.config/wireplumber/main.lua.d
    install -m 644 -o $U -g $U xiaozhi/99-cd18781y-alsa.lua $H/.config/wireplumber/main.lua.d/
    install -d /etc/wireplumber/main.lua.d
    install -m 644 xiaozhi/99-cd18781y-alsa.lua /etc/wireplumber/main.lua.d/
    # No core dumps (a crashing browser filled the disk); services this device has no use for
    install -d /etc/systemd/coredump.conf.d
    install -m 644 kiosk/coredump-off.conf /etc/systemd/coredump.conf.d/90-thinksmart-kiosk.conf
    # Time servers reachable from China (no RTC battery: the clock is set from the network each boot)
    install -d /etc/systemd/timesyncd.conf.d
    install -m 644 kiosk/timesyncd-cn.conf /etc/systemd/timesyncd.conf.d/thinksmart.conf
    # The proximity sensor is read straight from /dev/i2c-0, not through sudo i2cget once a second
    usermod -aG i2c $U
    # Wi-Fi power save off: the card misses DHCP replies with it (IPv4 minutes late after a boot)
    install -d /etc/NetworkManager/conf.d
    install -m 644 kiosk/wifi-powersave-off.conf /etc/NetworkManager/conf.d/zz-thinksmart-wifi-powersave-off.conf
    systemctl mask ModemManager.service avahi-daemon.service avahi-daemon.socket udisks2.service >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable thinksmart-gpu-watchdog.service screen-wake.service thinksmart-zram.service
    # reenable: its WantedBy moved from multi-user.target to sysinit.target
    systemctl reenable thinksmart-ssh-hostkeys.service
    # reenable: thinksmart-mic gained WantedBy=pipewire-pulse.service, so it comes back whenever
    # pipewire-pulse restarts; an existing install only has the default.target link
    user_systemctl daemon-reload
    user_systemctl reenable thinksmart-mic.service idle-blanker.service
    # Only welcome.html, keyboard.js and qrcode.js are used here; the rest is from the first chat
    # page and py-xiaozhi (vendor logos, an Edge TTS sample)
    rm -rf /usr/local/share/thinksmart-kiosk/chat.html /usr/local/share/thinksmart-kiosk/logos \
        /usr/local/share/thinksmart-kiosk/wake.wav
}

update() {
    [ -n "$1" ] || { echo "usage: device-setup.sh update CLIENT_DIR"; exit 1; }
    sh update/install.sh "$1"
}

kiosk() {
    install -m 644 kiosk/thinksmart-kiosk.service /etc/systemd/system/
    install -m 644 kiosk/thinksmart-kiosk.pam /etc/pam.d/thinksmart-kiosk
    rm -f /usr/share/wayland-sessions/thinksmart-kiosk.desktop /etc/sddm.conf.d/99-thinksmart-autologin.conf
    systemctl daemon-reload
    systemctl disable sddm.service 2>/dev/null || true
    rm -f /etc/systemd/system/display-manager.service
    systemctl enable thinksmart-kiosk.service
    systemctl set-default graphical.target
    # rotation-daemon only drives kscreen-doctor (Plasma); the kiosk takes ROTATION from its config
    systemctl --global disable rotation-daemon.service 2>/dev/null || true
    rm -f /etc/xdg/systemd/user/rotation-daemon.service /usr/local/bin/rotation-daemon.py
}

# Desktop, toolkits and helpers nothing of ours uses (TODO-remove-desktop.md). The browser is
# WebKitGTK 4.1 on GTK 3 under Weston; audio is PipeWire; fonts and the patched Mesa stay.
PURGE="sddm sddm-theme-* plasma-* kwin-* kwin-common libkwin* kglobalacceld kio-extras kde-* kf6-* libkf5* libkf6*
 qt6-* libqt6* qml6-* qml-module-* breeze* maliit-* qmlkonsole systemsettings xdg-desktop-portal-kde drkonqi
 gnome-terminal* baloo* milou polkit-kde-agent-1 powerdevil* bluedevil kscreen libkscreen* kwayland* layer-shell-qt
 pocketsphinx* speech-dispatcher* fonts-noto-cjk-extra fonts-mplus anthy* libanthy* samba-libs libsmbclient0
 libqt5* qt5-* libllvm18 libclang1-18 libclang-cpp18 modemmanager"
# Kept on purpose even if the purge would orphan them
KEEP="weston gir1.2-webkit2-4.1 libwebkit2gtk-4.1-0 gir1.2-gtk-3.0 python3-gi
 pipewire pipewire-pulse wireplumber libspa-0.2-modules pulseaudio-utils alsa-utils
 libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers
 fonts-noto-cjk fonts-noto-core fonts-noto-ui-core fonts-noto-mono fonts-noto-color-emoji fonts-dejavu-core fonts-dejavu-mono
 locales tzdata network-manager wpasupplicant bluez openssh-server sudo git curl ffmpeg
 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav python3-smbus2 python3-dbus i2c-tools"

purge() {
    # set -f: the patterns are for dpkg-query, not for the shell
    installed() ( set -f; dpkg-query -W -f='${Package} ${Status}\n' $1 2>/dev/null | awk '/ installed$/{print $1}' )
    keep=$(installed "$KEEP")
    # shellcheck disable=SC2086
    apt-mark manual $keep >/dev/null
    pkgs=$(installed "$PURGE" | grep -v -x -F "$keep" || true)
    if [ "$1" = -n ]; then
        # shellcheck disable=SC2086
        apt-get -s purge --autoremove $pkgs | grep -E '^(Purg|Remv|Inst)' | sort
        return
    fi
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get -y purge --autoremove $pkgs
    # KDE neon's repository only served the desktop
    rm -f /etc/apt/sources.list.d/plasmon.sources /usr/share/keyrings/kde-neon-archive-keyring.gpg
    apt-get clean
    rm -rf /var/lib/apt/lists/* $H/.cache/plasma* $H/.cache/k* $H/.cache/icon-cache.kcache $H/.local/share/baloo
}

tidy() {
    # Journal on disk so a crash can be read after the reboot, capped for the 8 GB eMMC
    install -d /etc/systemd/journald.conf.d
    printf '[Journal]\nStorage=persistent\nSystemMaxUse=64M\nSystemKeepFree=300M\nMaxRetentionSec=1month\n' \
        > /etc/systemd/journald.conf.d/thinksmart.conf
    install -d -g systemd-journal -m 2755 /var/log/journal
    systemctl restart systemd-journald
    timedatectl set-timezone Asia/Shanghai
    # rsyslog wrote every journal line again into /var/log, outside the journal's cap (169 MB there)
    systemctl disable --now rsyslog.service 2>/dev/null || true
    rm -f /var/log/syslog* /var/log/auth.log* /var/log/kern.log* /var/log/user.log* /var/log/messages*
    echo Asia/Shanghai > /etc/timezone
    # Earlier experiments: py-xiaozhi and the first chat page (replaced by thinksmart-client), Plasma-era helpers
    systemctl disable --now py-xiaozhi.service 2>/dev/null || true
    rm -f /etc/systemd/system/py-xiaozhi.service /usr/local/bin/thinksmart-chat.py /usr/local/bin/screen-wake-daemon.py.july
    user_systemctl disable thinksmart-chat.service accel-wake.service kde-baloo.service 2>/dev/null || true
    rm -f $UCONF/thinksmart-chat.service $UCONF/accel-wake.service $UCONF/kde-baloo.service \
        $UCONF/tas5782m-preinit.service.bak-* $UCONF/plasma-*.service
    rm -rf $UCONF/plasma-core.target.wants $UCONF/plasma-plasmashell.service.d
    rm -rf $H/py-xiaozhi $H/.local/share/py-xiaozhi $H/.local/bin/accel-wake.py $H/.local/bin/wake-daemon.py \
        $H/.local/bin/fix-rotation.sh $H/current
    # The client runs from /opt/thinksmart/client now (update step); the old checkout is unused
    rm -rf $H/thinksmart-client
    rm -rf /etc/sddm.conf /etc/sddm.conf.d /etc/sddm.conf.d.bak /usr/share/sddm /usr/share/plasma
    # a stray file next to ModemManager.service's mask (the purge left it)
    [ -L /etc/systemd/system/ModemManager.service ] && rm -f /etc/systemd/system/ModemManager
    dpkg -l | awk '/^rc/{print $2}' | xargs -r dpkg --purge
    # The screen daemons log to the journal now (their own files grew without bound)
    rm -f $H/.local/share/idle-blanker.log $H/.local/share/proximity-daemon.log $H/.local/share/rotation-daemon.log
    systemctl daemon-reload
}

codec() {
    (cd codec-dmic/out && md5sum -c --quiet ../expected.md5) \
        || { echo "codec-dmic/out/ missing or not the expected build: run codec-dmic/build.sh"; exit 1; }
    mod=/lib/modules/$(uname -r)/kernel/sound/soc/codecs/snd-soc-msm8916-digital.ko
    install -m 644 codec-dmic/out/snd-soc-msm8916-digital.ko "$mod"
    install -m 644 codec-dmic/out/apq8053-lenovo-cd-18781y.dtb /boot/apq8053-lenovo-cd-18781y.dtb
    depmod -a
    sync
    echo "installed; reboot to load them"
}

# Packages the first, hand-built camera bring-up installed on the device to compile libcamera
# there (camera/README.md); none of them is needed at run time
CAMERA_BUILD_ONLY="systemd-dev libpciaccess-dev libdrm-dev xorg-sgml-doctools x11proto-dev libxau-dev
 libxdmcp-dev xtrans-dev libpthread-stubs0-dev libxcb1-dev libx11-dev libglx-dev libgl-dev libegl-dev
 libevent-dev libgles-dev libgmp-dev libidn2-dev libp11-kit-dev libtasn1-6-dev nettle-dev libgnutls28-dev
 libjpeg-turbo8-dev libjpeg8-dev libjpeg-dev libudev-dev ninja-build pkgconf pkgconf-bin"

camera() {
    (cd camera/out && md5sum -c --quiet ../expected.md5) \
        || { echo "camera/out/ missing or not the expected build: run camera/build.sh"; exit 1; }
    deb=$(ls camera/out/thinksmart-camera_*_arm64.deb 2>/dev/null | sort -V | tail -1)
    [ -n "$deb" ] || { echo "no camera/out/thinksmart-camera_*_arm64.deb: run camera/build-libcamera.sh"; exit 1; }
    rel=$(uname -r)
    for m in s5kc505a v4l2loopback; do
        v=$(modinfo -F vermagic camera/out/$m.ko | cut -d' ' -f1)
        [ "$v" = "$rel" ] || { echo "camera/out/$m.ko is for kernel $v, this is $rel"; exit 1; }
    done
    install -d /lib/modules/$rel/extra
    install -m 644 camera/out/s5kc505a.ko camera/out/v4l2loopback.ko /lib/modules/$rel/extra/
    depmod -a
    # the DMIC fix is in this DTB too (camera/build.sh applies the codec-dmic patch)
    install -m 644 camera/out/apq8053-lenovo-cd-18781y.dtb /boot/apq8053-lenovo-cd-18781y.dtb

    # leftovers of the hand-built bring-up: its /usr/local install (the package replaces it),
    # sources, test output and the manual-load switch
    if ! dpkg-query -W -f='${Status}' thinksmart-camera 2>/dev/null | grep -q 'ok installed'; then
        rm -rf /usr/local/include/libcamera /usr/local/libexec/libcamera /usr/local/share/libcamera \
            /usr/local/lib/aarch64-linux-gnu/libcamera* /usr/local/lib/aarch64-linux-gnu/pkgconfig/libcamera* \
            /usr/local/lib/libcamera* /usr/local/lib/pkgconfig/libcamera* \
            /usr/local/bin/cam /usr/local/bin/libcamerify /usr/local/bin/tscam-bridge
    fi
    rm -rf $H/src/libcamera $H/src/meson-* $H/camera $H/camera-test*
    rmdir $H/src 2>/dev/null || true
    rm -f /etc/modprobe.d/s5kc505a-manual.conf /etc/ld.so.conf.d/libcamera-local.conf

    # apt resolves the package's runtime libraries (the purge step empties the lists)
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "./$deb"
    installed() ( set -f; dpkg-query -W -f='${Package} ${Status}\n' $1 2>/dev/null | awk '/ installed$/{print $1}' )
    # Only these packages, one at a time, never --autoremove: the bring-up's apt run upgraded systemd
    # and udev as dependencies and left them marked automatic, and some of these -dev packages are
    # tied to systemd's version. A package is purged only if apt can remove it without touching
    # anything outside this list; whatever cannot be removed cleanly stays (it only costs disk space).
    left=$(installed "$CAMERA_BUILD_ONLY")
    progress=1
    while [ -n "$left" ] && [ $progress = 1 ]; do
        progress=0
        for p in $left; do
            sim=$(apt-get -s purge "$p" 2>/dev/null) || continue
            gone=$(echo "$sim" | awk '/^(Purg|Remv) /{print $2}')
            [ -z "$(echo "$gone" | grep -v -x -F "$left")" ] || continue
            # shellcheck disable=SC2086
            DEBIAN_FRONTEND=noninteractive apt-get -y -q purge $gone >/dev/null && progress=1
        done
        left=$(installed "$CAMERA_BUILD_ONLY")
    done
    [ -z "$left" ] || echo "build-only packages kept (apt would remove more than them):" $left
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    install -m 644 camera/thinksmart-camera.service /etc/systemd/system/
    install -m 644 camera/70-libcamera-dmabuf.rules /etc/udev/rules.d/
    install -m 644 camera/v4l2loopback-options.conf /etc/modprobe.d/v4l2loopback.conf
    install -m 644 camera/v4l2loopback-load.conf /etc/modules-load.d/v4l2loopback.conf
    # libcamera applications as the owner: the software ISP allocates through /dev/udmabuf
    usermod -aG video $U
    systemctl daemon-reload
    systemctl enable thinksmart-camera.service
    sync
    echo "installed; reboot to load the new DTB, then: cam -l; v4l2-ctl -d /dev/video10 --all"
}

alsa_plugin() {
    [ -f "${1:-}" ] || { echo "usage: device-setup.sh alsa-plugin pipewire-alsa_1.0.5-*_arm64.deb"; exit 1; }
    t=$(mktemp -d)
    dpkg-deb -x "$1" "$t"
    install -m 644 "$t"/usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_pipewire.so \
        "$t"/usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_ctl_pipewire.so /usr/lib/aarch64-linux-gnu/alsa-lib/
    install -m 644 "$t"/usr/share/alsa/alsa.conf.d/50-pipewire.conf /usr/share/alsa/alsa.conf.d/
    ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf
    rm -rf "$t"
}

hold() {
    # shellcheck disable=SC2046
    apt-mark hold $(grep -v '^#' image/held-packages.txt) >/dev/null
    apt-mark showhold
}

case "$1" in
    files|kiosk|tidy|codec|camera|hold) "$1" ;;
    update|purge) cmd=$1; shift; "$cmd" "$@" ;;
    alsa-plugin) shift; alsa_plugin "$@" ;;
    *) sed -n '2,24p' "$0"; exit 1 ;;
esac
