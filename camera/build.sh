#!/bin/bash
# Build the kernel side of the front camera against the kernel build tree in the docker volume
# kbuild-src (made by ../kernel/build.sh; mounted read-only, nothing in it changes):
#   - the S5KC505A sensor driver (s5kc505a/)
#   - v4l2loopback (pinned upstream release), for the /dev/video10 webcam
#   - the CD-18781Y DTB: the stock one with the DMIC fix (../codec-dmic) plus the camera nodes
#     (apq8053-lenovo-cd-18781y-camera.dtsi). It replaces codec-dmic's DTB on the device.
# The modules are built out of tree, so they carry the same vermagic as the running kernel.
# Output: out/s5kc505a.ko, out/v4l2loopback.ko, out/apq8053-lenovo-cd-18781y.dtb (expected.md5)
set -euo pipefail
cd "$(dirname "$0")"
V4L2LB_TAG=v0.15.4
V4L2LB_COMMIT=0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4
mkdir -p out
# the kernel build image has no git: fetch on the host, check the commit
[ -d out/v4l2loopback ] || git clone -q --depth 1 --branch $V4L2LB_TAG https://github.com/umlaeute/v4l2loopback out/v4l2loopback
[ "$(git -C out/v4l2loopback rev-parse HEAD)" = $V4L2LB_COMMIT ] \
    || { echo "out/v4l2loopback is not $V4L2LB_TAG ($V4L2LB_COMMIT): remove it and run again"; exit 1; }

docker run --rm -v kbuild-src:/build:ro -v "$PWD":/w -v "$PWD/../codec-dmic":/dmic:ro kbuild:clang21 bash -euc '
K=/build/linux-6.19.5-r0
T=$(mktemp -d)

mod() {   # mod NAME SRC_DIR
    mkdir -p $T/$1; cp -r "$2"/. $T/$1/
    make -s -C $K ARCH=arm64 LLVM=1 M=$T/$1 modules
    llvm-strip --strip-debug -o /w/out/$1.ko $T/$1/$1.ko
}
mod s5kc505a /w/s5kc505a
mod v4l2loopback /w/out/v4l2loopback

# the DTB: stock source, the DMIC patch (as codec-dmic/build.sh does), then the camera nodes
mkdir -p $T/src/sound/soc/codecs $T/src/arch/arm64/boot/dts/qcom $T/src/Documentation/devicetree/bindings/sound
cp $K/sound/soc/codecs/msm8916-wcd-digital.c $T/src/sound/soc/codecs/
cp $K/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts $T/src/arch/arm64/boot/dts/qcom/
cp $K/Documentation/devicetree/bindings/sound/qcom,msm8916-wcd-digital-codec.yaml $T/src/Documentation/devicetree/bindings/sound/
(cd $T/src && patch -s -p1 < /dmic/msm8916-wcd-digital-dmic-clock.patch)
D=$T/src/arch/arm64/boot/dts/qcom
cp /w/apq8053-lenovo-cd-18781y-camera.dtsi $D/
printf "\n#include \"apq8053-lenovo-cd-18781y-camera.dtsi\"\n" >> $D/apq8053-lenovo-cd-18781y.dts
# the way the kernel build does it (same as codec-dmic/build.sh)
clang -E -nostdinc -I$K/include -I$K/arch/arm64/boot/dts -I$K/arch/arm64/boot/dts/qcom \
    -I$K/scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp -P -o $T/pre.dts $D/apq8053-lenovo-cd-18781y.dts
$K/scripts/dtc/dtc -q -O dtb -o /w/out/apq8053-lenovo-cd-18781y.dtb -b 0 -i $D -i $K/arch/arm64/boot/dts/qcom $T/pre.dts

cd /w/out
md5sum -c ../expected.md5
for m in s5kc505a v4l2loopback; do
    echo "$m.ko: $(strings $m.ko | grep -m1 ^vermagic=)"
done
'
ls -l out/*.ko out/*.dtb
