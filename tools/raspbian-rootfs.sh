#!/bin/bash
#
# Create a Raspbian root filesystem (the userland of 32-bit Raspberry Pi OS,
# built for ARMv6 so it runs on every Pi including the Zero and Pi 1), for
# building and testing on a non-ARM machine under QEMU.
#
#   sudo tools/raspbian-rootfs.sh DIST DIR [extra packages...]
#
# DIST is a Raspbian release (bookworm, trixie). Needs root, curl, gpg,
# debootstrap, and ARM binfmt support (qemu-user-static, or
# docker/setup-qemu-action on GitHub Actions).
#
# Then run commands on an emulated Pi Zero / Pi 1 CPU (ARM1176: ARMv6, no
# NEON) with:
#
#   sudo chroot DIR env QEMU_CPU=arm1176 bash -c '...'

set -eu

DIST=$1
DIR=$2
shift 2

PACKAGES=build-essential,pkg-config,libncurses-dev,python3,python3-numpy,git,ca-certificates
for p in "$@"; do PACKAGES=$PACKAGES,$p; done

KEY=$(mktemp)
trap 'rm -f "$KEY"' EXIT
curl -fsSL https://archive.raspbian.org/raspbian.public.key | gpg --dearmor > "$KEY"

debootstrap --arch=armhf --keyring="$KEY" --variant=minbase --include="$PACKAGES" \
    "$DIST" "$DIR" http://raspbian.raspberrypi.com/raspbian

mount -t proc proc "$DIR/proc"
mount --bind /dev "$DIR/dev"
cp /etc/resolv.conf "$DIR/etc/resolv.conf"
echo "Raspbian $DIST root filesystem ready in $DIR" >&2
