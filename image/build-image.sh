#!/bin/bash
# Build the release image from a capture made by pull-from-device.sh:
#   image/build-image.sh WORK_DIR OUT_DIR HUB_REPO [SECRETS_FILE]
# WORK_DIR   has root.tar.zst, boot.tar.zst, versions.txt (hub commit, client version)
# OUT_DIR    gets <name>.img.xz, SHA256SUMS (.img.xz and .img), packages.txt
# HUB_REPO   a checkout of xiaozhi-hub-server holding the captured commit (for the config template)
# SECRETS_FILE (optional, keep it outside any repository) one literal string per line that must not
#            appear anywhere in the image: Wi-Fi names, API keys, device ids, the owner's e-mail...
# HUB_MAIN   (environment, default origin/main, fetched first) the hub's published main: the shipped
#            commit must be on it, or every device's scripts/update.sh (git merge --ff-only) fails.
#            HUB_MAIN=main checks against the local main before it is pushed (push before releasing).
#
# The image is the "system" partition content, like upstream's: an MBR disk with pmOS_boot (ext2) and
# pmOS_root (ext4) at the original offsets and UUIDs, root shrunk to its content plus headroom. The
# pmOS initramfs grows root to the whole partition on first boot. Flash with: edl w system <image>
# Runs everything that needs root inside a container (image/Dockerfile); the work tree lives in a
# Docker volume so ownership, devices and capabilities survive.
set -euo pipefail
WORK=$(cd "${1:?work dir}" && pwd); OUT=${2:?out dir}; HUB=$(cd "${3:?hub repo}" && pwd); SECRETS=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
read -r HUB_COMMIT CLIENT_VERSION < <(paste -sd' ' "$WORK/versions.txt")
NAME=${IMAGE_NAME:-thinksmart-ubuntu-$(date +%Y%m%d)}
HUB_MAIN=${HUB_MAIN:-origin/main}
[ "$HUB_MAIN" = origin/main ] && git -C "$HUB" fetch -q origin main
git -C "$HUB" merge-base --is-ancestor "$HUB_COMMIT" "$HUB_MAIN" || {
    echo "hub commit $HUB_COMMIT is not on $HUB_MAIN: merge it into main (fast-forward) first"; exit 1; }
git -C "$HUB" show "$HUB_COMMIT:scripts/config.template.yaml" > "$WORK/hub-config.template.yaml"
[ -n "$SECRETS" ] && cp "$SECRETS" "$WORK/secrets.txt" || : > "$WORK/secrets.txt"

# the DMIC fix must be the codec-dmic build (it only exists on the device and in codec-dmic/out);
# the DTB is camera/build.sh's, which is codec-dmic's DTB plus the front camera nodes
KO_MD5=$(awk '/snd-soc-msm8916-digital.ko/{print $1}' "$HERE/../codec-dmic/expected.md5")
DTB_MD5=$(awk '/apq8053-lenovo-cd-18781y.dtb/{print $1}' "$HERE/../camera/expected.md5")
docker build -q -t thinksmart-image "$HERE" >/dev/null 2>&1
docker volume create tsimg-work >/dev/null
docker run --rm -i -v tsimg-work:/w -v "$WORK:/in:ro" -v "$OUT:/out" -v "$HERE:/s:ro" \
    -e NAME="$NAME" -e HUB_COMMIT="$HUB_COMMIT" -e CLIENT_VERSION="$CLIENT_VERSION" -e KO_MD5="$KO_MD5" -e DTB_MD5="$DTB_MD5" \
    thinksmart-image bash -s <<'EOF'
set -euo pipefail
BOOT_UUID=35bca636-764e-4f53-b5e5-96eb774eb19e
ROOT_UUID=8b6cd6d2-cf64-4279-b1cc-426345d5b822
BOOT_START=2048 BOOT_SECTORS=509952 ROOT_START=512000
log() { echo "== $*"; }

log "unpack"
rm -rf /w/root /w/boot /w/*.img /w/caps.txt
mkdir -p /w/root /w/boot
zstd -dc /in/root.tar.zst | tar -x --numeric-owner --xattrs --xattrs-include='*' --acls -p -C /w/root
zstd -dc /in/boot.tar.zst | tar -x --numeric-owner -p -C /w/boot
rm -f /w/boot/*.orig
R=/w/root

log "USB network: NCM instead of RNDIS (macOS has no RNDIS)"
sh /s/initramfs-usb-ncm.sh /w/boot/initramfs

log "sanitize"
sh /s/sanitize-rootfs.sh $R /in/hub-config.template.yaml

log "files the image must carry: DMIC fix, camera, audio rules, ALSA plugin, user unit links"
# camera/build.sh output (camera/expected.md5): the DTB with qcom,dmic-sample-rate and the camera nodes;
# codec-dmic/build.sh output (codec-dmic/expected.md5): the codec module
need() { [ -e "$1" ] || { echo "missing: ${1#$R}"; exit 1; }; }
need /w/boot/apq8053-lenovo-cd-18781y.dtb
[ "$(md5sum < /w/boot/apq8053-lenovo-cd-18781y.dtb | cut -d' ' -f1)" = "$DTB_MD5" ] \
    || { echo "/boot DTB is not the camera/ build (device-setup.sh camera): no camera, and without the DMIC fix the second mic would be noise"; exit 1; }
ko=$(echo $R/usr/lib/modules/*/kernel/sound/soc/codecs/snd-soc-msm8916-digital.ko)
need "$ko"
[ "$(md5sum < "$ko" | cut -d' ' -f1)" = "$KO_MD5" ] || { echo "codec module is not the codec-dmic build"; exit 1; }
# front camera (device-setup.sh camera): modules for the image's kernel, the libcamera package,
# the webcam service enabled, and nothing left of the hand-built bring-up
for m in s5kc505a v4l2loopback; do
    ko=$(echo $R/usr/lib/modules/*/extra/$m.ko)
    need "$ko"
done
awk '$0 == "Package: thinksmart-camera" {f = 1; next} f && /^Status:/ {print; exit}' $R/var/lib/dpkg/status |
    grep -q ' installed$' || { echo "thinksmart-camera package not installed (device-setup.sh camera)"; exit 1; }
need $R/usr/local/bin/tscam-bridge
need $R/usr/local/share/libcamera/ipa/softisp/s5kc505a.yaml
need $R/etc/udev/rules.d/70-libcamera-dmabuf.rules
need $R/etc/modules-load.d/v4l2loopback.conf
[ -L $R/etc/systemd/system/multi-user.target.wants/thinksmart-camera.service ] \
    || { echo "thinksmart-camera.service not enabled (device-setup.sh camera)"; exit 1; }
grep -qE '^video:.*[:,]ubuntu(,|$)' $R/etc/group || { echo "ubuntu is not in the video group (device-setup.sh camera)"; exit 1; }
for p in home/ubuntu/src/libcamera usr/local/include/libcamera etc/modprobe.d/s5kc505a-manual.conf; do
    [ ! -e $R/$p ] || { echo "camera bring-up leftover: /$p (device-setup.sh camera)"; exit 1; }
done
# speaker S16LE and the disabled DSP capture node; without it the speaker is almost silent
need $R/home/ubuntu/.config/wireplumber/main.lua.d/99-cd18781y-alsa.lua
# PipeWire's ALSA plugin, installed by hand, not by dpkg (device-setup.sh alsa-plugin)
need $R/usr/lib/aarch64-linux-gnu/alsa-lib/libasound_module_pcm_pipewire.so
need $R/usr/share/alsa/alsa.conf.d/50-pipewire.conf
# user units enabled (device-setup.sh files); the mic link brings it back after pipewire-pulse restarts
for l in default.target.wants/thinksmart-mic.service default.target.wants/idle-blanker.service \
         pipewire-pulse.service.wants/thinksmart-mic.service; do
    [ -L $R/home/ubuntu/.config/systemd/user/$l ] || { echo "missing user unit link: $l"; exit 1; }
done
# the tested versions stay put (device-setup.sh hold): dpkg marks them "hold ok installed"
# (/s is this directory; the list is read into a variable first so a missing file stops the build
# instead of giving the loop nothing to check)
held=$(grep -v -e '^#' -e '^[[:space:]]*$' /s/held-packages.txt)
[ -n "$held" ] || { echo "held-packages.txt is empty"; exit 1; }
n=0
for p in $held; do
    awk -v p="$p" '$0 == "Package: " p {f = 1; next} f && /^Status:/ {print; exit}' $R/var/lib/dpkg/status |
        grep -q '^Status: hold ' || { echo "not held: $p (device-setup.sh hold)"; exit 1; }
    n=$((n + 1))
done
echo "held packages: $n"
# Chinese time servers, rsyslog off (device-setup.sh files / tidy)
need $R/etc/systemd/timesyncd.conf.d/thinksmart.conf
[ ! -e $R/etc/systemd/system/multi-user.target.wants/rsyslog.service ] || { echo "rsyslog still enabled (device-setup.sh tidy)"; exit 1; }
# Wi-Fi power save off (device-setup.sh files)
need $R/etc/NetworkManager/conf.d/zz-thinksmart-wifi-powersave-off.conf
echo "ok"

log "no macOS leftovers"
find $R /w/boot -xdev \( -name '._*' -o -name .DS_Store -o -name __MACOSX \) > /w/macos.txt
[ ! -s /w/macos.txt ] || { echo "macOS files left (a ._ file that is not AppleDouble needs a look):"; sed "s|^/w/||" /w/macos.txt | head; exit 1; }
echo "ok"

log "hub data/ fresh, no backup copies"
# data/ holds exactly what sanitize-rootfs.sh wrote: the template config and the install marker
got=$(ls -A $R/home/ubuntu/xiaozhi-hub-server/main/xiaozhi-server/data | sort | tr '\n' ' ')
[ "$got" = ".config.yaml .install-complete " ] || { echo "hub data/ is not fresh: $got"; exit 1; }
find $R/etc $R/home $R/root $R/opt $R/usr/local -xdev \
    \( -name '*.bak*' -o -name '*.orig' -o -name '*.old' -o -name '*.save' -o -name '*~' \
       -o -name '*.dpkg-old' -o -name '*.dpkg-dist' -o -name '*.ucf-old' \) \
    -not -path '*/site-packages/*' -not -path '*/.venv/*' > /w/backups.txt
[ ! -s /w/backups.txt ] || { echo "backup copies left:"; sed "s|^$R||" /w/backups.txt | head; exit 1; }
echo "ok"

log "hub repository: $HUB_COMMIT as main, tracking origin/main"
# as the owner (uid 1000), so .git stays ubuntu's
G() { setpriv --reuid=1000 --regid=1000 --clear-groups env HOME=/tmp git -c 'safe.directory=*' -C $R/home/ubuntu/xiaozhi-hub-server "$@"; }
[ "$(G rev-parse HEAD)" = "$HUB_COMMIT" ] || { echo "hub HEAD is not $HUB_COMMIT"; exit 1; }
# rewritten below; a power cut right after the admin page's update check leaves them zero-filled
rm -f $R/home/ubuntu/xiaozhi-hub-server/.git/FETCH_HEAD $R/home/ubuntu/xiaozhi-hub-server/.git/refs/remotes/origin/main
G checkout -q -B main "$HUB_COMMIT"
G for-each-ref --format='%(refname)' refs/heads refs/remotes refs/stash | { grep -v -x -e refs/heads/main -e refs/remotes/origin/main -e refs/remotes/origin/HEAD || true; } \
    | while read -r ref; do G update-ref -d "$ref"; done || true
G remote | { grep -v -x origin || true; } | while read -r r; do G remote remove "$r"; done
G remote set-url origin https://github.com/justhalfbit/xiaozhi-hub-server.git
# The commit is on the published main (checked on the host), so origin/main may point at it
G update-ref refs/remotes/origin/main "$HUB_COMMIT"
G branch -q -u origin/main main
G config --unset-all http.proxy 2>/dev/null || true
G reflog expire --expire=now --all
G gc -q --prune=now
[ -z "$(G status --porcelain)" ] || { echo "hub working tree is not clean:"; G status --short | head; exit 1; }

log "capabilities to check after mke2fs"
getcap -r $R/usr 2>/dev/null | sed "s|^$R||" > /w/caps.txt || true
cat /w/caps.txt

log "disk layout"
used_mb=$(du -s --block-size=1M -x $R | cut -f1)
files=$(find $R -xdev | wc -l)
# content + 12% + 200 MB: mke2fs metadata and the journal; first boot grows it to the whole partition
root_mb=$(( used_mb * 112 / 100 + 200 ))
root_sectors=$(( root_mb * 2048 ))
inodes=$(( files * 2 > 200000 ? files * 2 : 200000 ))
rm -f /w/disk.img
truncate -s $(( (ROOT_START + root_sectors) * 512 )) /w/disk.img
sfdisk -q /w/disk.img <<SF
label: dos
label-id: 0x37d1617d
unit: sectors
start=$BOOT_START, size=$BOOT_SECTORS, type=83
start=$ROOT_START, size=$root_sectors, type=83
SF
sfdisk -d /w/disk.img
# The filesystems are made in place (-E offset): no second copy of the root filesystem on disk
BOOT_FS="/w/disk.img?offset=$((BOOT_START*512))"
ROOT_FS="/w/disk.img?offset=$((ROOT_START*512))"

log "boot filesystem"
mke2fs -q -t ext2 -b 4096 -L pmOS_boot -U $BOOT_UUID -E root_owner=0:0,offset=$((BOOT_START*512)) \
    -d /w/boot /w/disk.img $((BOOT_SECTORS/8))
e2fsck -fn "$BOOT_FS" >/dev/null

log "root filesystem"
mke2fs -q -t ext4 -b 4096 -I 256 -N $inodes -L pmOS_root -U $ROOT_UUID \
    -O has_journal,ext_attr,resize_inode,dir_index,filetype,extent,64bit,flex_bg,sparse_super,large_file,huge_file,dir_nlink,extra_isize,metadata_csum,^orphan_file,^metadata_csum_seed \
    -E root_owner=0:0,offset=$((ROOT_START*512)) -d $R /w/disk.img $((root_sectors/8))
e2fsck -fn "$ROOT_FS" >/dev/null
echo "content ${used_mb} MB, $files files -> root ${root_mb} MB, $inodes inodes"
dumpe2fs -h "$ROOT_FS" 2>/dev/null | awk -F: '/^Free blocks/{printf "free in root: %d MB\n", $2*4/1024} /^Free inodes/{print "free inodes:" $2}'
while read -r path cap; do
    got=$(debugfs -R "ea_get $path security.capability" "$ROOT_FS" 2>/dev/null | head -1)
    [ -n "$got" ] || { echo "capability lost: $path ($cap)"; exit 1; }
done < /w/caps.txt
echo "capabilities kept: $(wc -l < /w/caps.txt)"
[ "$(stat -c %s /w/disk.img)" = $(( (ROOT_START + root_sectors) * 512 )) ] || { echo "mke2fs changed the image size"; exit 1; }

log "privacy check over the whole image"
fail=0
check() {  # label, then grep arguments
    local label=$1; shift
    n=$(grep -a -c "$@" /w/disk.img || true)
    printf '%-28s %s\n' "$label" "$n"; [ "$n" = 0 ] || fail=1
}
check "ssh-ed25519 public keys" -F -e "ssh-ed25519 AAAA"
check "ssh-rsa public keys"     -F -e "ssh-rsa AAAA"
# Real keys are long runs of letters and digits; "sk-"/"xai-" alone match ordinary words (disk-, ssh-sk-helper)
check "sk- API keys"            -E -e "sk-[A-Za-z0-9]{32,}"
check "xai- API keys"           -E -e "xai-[A-Za-z0-9]{32,}"
check "owner e-mail"            -F -e "qiuhe.zhang"
# a host on the owner's LAN (requests' docstring has the network 192.168.100.0/24, which is fine)
check "LAN host 192.168.100.x"  -E -e "192\.168\.100\.[1-9][0-9]{0,2}([^0-9/]|$)"
check "Mac proxy 127.0.0.1:7897" -F -e "127.0.0.1:7897"
n=0
while IFS= read -r s; do
    [ -n "$s" ] || continue
    c=$(grep -a -c -F -e "$s" /w/disk.img || true)
    [ "$c" = 0 ] || { echo "secret #$((n+1)) found $c times"; fail=1; }
    n=$((n+1))
done < /in/secrets.txt
echo "owner secrets checked: $n"
[ $fail = 0 ] || { echo "privacy check FAILED"; exit 1; }

log "package list"
awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Status:/{s=$0} /^$/{if (s ~ / installed$/) print p, v; s=""}' \
    $R/var/lib/dpkg/status | sort > /out/packages.txt
wc -l < /out/packages.txt

log "compress"
mv /w/disk.img /w/$NAME.img
# -9 needs ~670 MB per thread: 4 threads fit the default Docker VM
xz -T4 -9 -c /w/$NAME.img > /out/$NAME.img.xz
# both: the compressed download, and the image after `xz -d` (sha256sum -c --ignore-missing before unpacking)
( cd /out && sha256sum $NAME.img.xz > SHA256SUMS )
( cd /w && sha256sum $NAME.img >> /out/SHA256SUMS )
echo "$NAME.img $(stat -c %s /w/$NAME.img) bytes, sha256 $(sha256sum /w/$NAME.img | cut -d' ' -f1)" > /out/image-info.txt
rm -f /w/$NAME.img
ls -l /out
cat /out/image-info.txt
EOF
