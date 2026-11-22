#!/bin/bash
#
# Build an installable test package (.deb) of this branch, for a live trial
# on a Raspberry Pi or other Debian-based feeder.
#
#   tools/build-test-package.sh [--dist bookworm|trixie] [--number N] [--install-deps] [--out DIR]
#
#   --dist DIST       target distribution (default: this machine's, from /etc/os-release)
#   --number N        test build number; the package version becomes e.g. 11.1+testN
#                     (default: $GITHUB_RUN_NUMBER on GitHub Actions, else 0)
#   --install-deps    install the build dependencies with apt-get first
#   --out DIR         where to put the .deb (default: ./test-packages)
#
# The version sorts above the official release it is based on (11.1+test3 >
# 11.1), so the normal updater does not quietly replace it, and below the
# next official release (11.2), which replaces it as usual. dump1090-fa
# --version, the logs and the stats all show the test version.
#
# GitHub Actions builds these for bookworm and trixie on arm64, armhf and
# amd64 (.github/workflows/packages.yaml). The armhf packages need an ARMv7
# or newer CPU (Pi 2 and later); on a Pi Zero or Pi 1 (ARMv6), build the
# package on the Pi itself with this script (slow, but it works).
#
# Builds the committed state of HEAD (uncommitted changes are not included).

set -eu

TOP=$(cd "$(dirname "$0")/.." && pwd)
DIST=
NUMBER=${GITHUB_RUN_NUMBER:-0}
INSTALL_DEPS=0
OUT=$PWD/test-packages

while [ $# -gt 0 ]; do
    case "$1" in
        --dist) DIST=$2; shift 2 ;;
        --number) NUMBER=$2; shift 2 ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --out) OUT=$2; shift 2 ;;
        *) sed -n '2,26p' "$0"; exit 2 ;;
    esac
done

[ -n "$DIST" ] || DIST=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
case "$DIST" in
    bookworm|trixie) ;;
    *) echo "unsupported or unknown distribution '$DIST' (use --dist bookworm or --dist trixie)" >&2; exit 2 ;;
esac
case "$NUMBER" in ''|*[!0-9]*) echo "--number must be a whole number" >&2; exit 2 ;; esac

SUDO=
[ "$(id -u)" = 0 ] || SUDO=sudo
if [ $INSTALL_DEPS = 1 ]; then
    $SUDO apt-get update -qq
    $SUDO apt-get install -y --no-install-recommends build-essential fakeroot debhelper devscripts git
fi
for c in git dch dpkg-buildpackage; do
    command -v $c >/dev/null || { echo "$c not found: install build-essential fakeroot debhelper devscripts git, or use --install-deps" >&2; exit 2; }
done

mkdir -p "$OUT"
OUT=$(realpath "$OUT")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$TOP"
COMMIT=$(git rev-parse --short HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ -z "$(git status --porcelain --untracked-files=no)" ] || echo "note: uncommitted changes are not included in the package" >&2

# a clean copy of HEAD, so no stale build products end up in the package
mkdir "$TMP/src"
git archive HEAD | tar -x -C "$TMP/src"
cd "$TMP/src"

export DEBFULLNAME=${DEBFULLNAME:-dump1090-fa test build}
export DEBEMAIL=${DEBEMAIL:-noreply@users.noreply.github.com}
BASEVER=$(dpkg-parsechangelog -S Version)
VERSION=$BASEVER+test$NUMBER
dch --newversion "$VERSION" --force-distribution --distribution stable \
    "Test build of $BRANCH at $COMMIT, based on $BASEVER. Not an official FlightAware release."
# not maintained by FlightAware, so don't name their maintainer in the package
sed -i "s|^Maintainer:.*|Maintainer: $DEBFULLNAME <$DEBEMAIL>|" debian/control
./prepare-build.sh "$DIST" "$TMP/pkg"
cd "$TMP/pkg"

if [ $INSTALL_DEPS = 1 ]; then
    $SUDO apt-get build-dep -y ./
fi

dpkg-buildpackage -b --no-sign -j"$(nproc)"
cp "$TMP"/*.deb "$OUT"/
echo
echo "Built:"
ls -1 "$TMP"/*.deb | xargs -n1 basename | sed "s|^|  $OUT/|"
