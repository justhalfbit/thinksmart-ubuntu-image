#!/bin/bash
# Build libcamera 0.8.0 for the front camera (simple pipeline, GPU software ISP, the S5KC505A
# sensor helper and tuning file) and tscam-bridge (the /dev/video10 webcam), packaged as
# out/thinksmart-camera_<version>_arm64.deb, in an ubuntu:24.04 arm64 container (colima on Apple
# Silicon, as for ../mesa). Building on the device itself needs -dev packages that conflict with
# this image's Mesa and KDE neon packages; the .deb only needs runtime libraries.
# Everything installs under /usr/local, next to (not over) Ubuntu's libcamera 0.2 packages.
#   camera/build-libcamera.sh
set -euo pipefail
LC_TAG=v0.8.0
LC_COMMIT=df8e348d64b4932a0676256ed24f0da3ee9438bc
PKG_VERSION=0.8.0-1

if [ "${1:-}" != --in-container ]; then
    cd "$(dirname "$0")"
    mkdir -p out
    docker run --rm --platform linux/arm64 -v "$PWD":/src:ro -v "$PWD/out":/out ubuntu:24.04 \
        bash /src/build-libcamera.sh --in-container
    ls -l out/*.deb
    exit 0
fi

# ---- inside the container ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates git g++ meson ninja-build pkg-config python3-yaml python3-ply python3-jinja2 \
    libyaml-dev libgnutls28-dev libudev-dev libevent-dev libdrm-dev libjpeg-dev libegl-dev libgles-dev \
    dpkg-dev binutils file >/dev/null

git clone -q --depth 1 --branch $LC_TAG https://github.com/libcamera-org/libcamera /tmp/libcamera
[ "$(git -C /tmp/libcamera rev-parse HEAD)" = $LC_COMMIT ] || { echo "libcamera $LC_TAG is not $LC_COMMIT"; exit 1; }
cd /tmp/libcamera
git apply /src/libcamera-s5kc505a.patch

meson setup build --prefix=/usr/local --buildtype=release \
    -Dpipelines=simple -Dipas=softisp -Dsoftisp-gpu=enabled \
    -Dcam=enabled -Dcam-output-sdl2=disabled -Dcam-output-kms=enabled -Dcam-jpeg=enabled \
    -Dgstreamer=disabled -Dqcam=disabled -Dv4l2=enabled -Dudev=enabled \
    -Dlibdw=disabled -Dlibunwind=disabled -Dtracing=disabled \
    -Dpycamera=disabled -Ddocumentation=disabled -Dtest=false -Dlc-compliance=disabled
ninja -C build
# into the container's /usr/local too, so tscam-bridge builds against it
ninja -C build install >/dev/null
P=/tmp/pkg
DESTDIR=$P ninja -C build install >/dev/null

export PKG_CONFIG_PATH=/usr/local/lib/aarch64-linux-gnu/pkgconfig
g++ -std=c++20 -O2 -Wall /src/tscam-bridge.cpp -o $P/usr/local/bin/tscam-bridge \
    $(pkg-config --cflags --libs libcamera)
install -D -m 644 /src/s5kc505a.yaml $P/usr/local/share/libcamera/ipa/softisp/s5kc505a.yaml
install -d $P/etc/ld.so.conf.d
echo /usr/local/lib/aarch64-linux-gnu > $P/etc/ld.so.conf.d/thinksmart-camera.conf

# runtime only: no headers, pkg-config files or unversioned .so links
# (the IPA module is a plain .so and stays; it is not stripped, which would break its signature)
rm -rf $P/usr/local/include $P/usr/local/lib/aarch64-linux-gnu/pkgconfig
find $P/usr/local/lib/aarch64-linux-gnu -maxdepth 1 -name 'lib*.so' -type l -delete

# Depends: the packages providing every shared library the binaries need
deps=$(find $P -type f -exec file {} + | awk -F: '/ELF/{print $1}' |
    xargs -n1 objdump -p | awk '/NEEDED/{print $2}' | sort -u |
    while read -r lib; do
        [ -n "$(find $P -name "$lib*" -print -quit)" ] && continue   # one of ours
        path=$(ldconfig -p | awk -v l="$lib" '$1 == l && /aarch64|AArch64/ {print $NF; exit}')
        [ -n "$path" ] || { echo "unresolved $lib" >&2; exit 1; }
        dpkg -S "$(readlink -f "$path")" 2>/dev/null | head -1 | cut -d: -f1
    done | sort -u | paste -sd, | sed 's/,/, /g')
echo "Depends: $deps"

mkdir -p $P/DEBIAN
cat > $P/DEBIAN/control <<CTL
Package: thinksmart-camera
Version: $PKG_VERSION
Architecture: arm64
Maintainer: thinksmart-ubuntu-image <noreply@github.com>
Depends: $deps
Section: video
Priority: optional
Description: ThinkSmart View front camera userspace (libcamera $LC_TAG + webcam bridge)
 libcamera $LC_TAG ($LC_COMMIT) with the simple pipeline, the GPU software ISP and
 S5KC505A sensor support, its cam tool and V4L2 compatibility layer, the S5KC505A
 tuning file, and tscam-bridge, which feeds the camera into a v4l2loopback device
 as a plain webcam. Installed under /usr/local.
CTL
printf '#!/bin/sh\nset -e\nldconfig\n' > $P/DEBIAN/postinst
cp $P/DEBIAN/postinst $P/DEBIAN/postrm
chmod 755 $P/DEBIAN/postinst $P/DEBIAN/postrm
dpkg-deb --root-owner-group -Zxz -b $P /out/thinksmart-camera_${PKG_VERSION}_arm64.deb
dpkg-deb -c /out/thinksmart-camera_${PKG_VERSION}_arm64.deb | awk '{print $6}' | grep -v '/$'
