#!/bin/bash
# Build rackglass for linux-arm64 inside an emulated container.
#
#   tools/arm64/build.sh [config file] [output dir]
#
# Defaults to config.pi.env and ./build/arm64-out. Needs podman, qemu-user-static
# and binfmt registration for aarch64:
#
#   sudo dnf install qemu-user-static-aarch64   # Fedora
#   sudo apt install qemu-user-static binfmt-support
#
# The first run builds the image and takes the better part of an hour under
# emulation. Later runs reuse it and take minutes.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
proj=$(cd "$here/../.." && pwd)
config=${1:-config.pi.env}
out=${2:-$proj/build/arm64-out}
img=rackglass-arm64-build

[ -f "$proj/$config" ] || { echo "no such config: $proj/$config" >&2; exit 1; }
mkdir -p "$out"

podman build --arch arm64 -t "$img" -f "$here/Containerfile" "$here" || exit 1

# TAR_OPTIONS: Flutter unpacks artifacts with tar as root, which then tries to
# restore ownership to uids from the archive. Inside podman's user namespace
# those uids are unmapped and the chown fails, taking the extraction with it.
#
# bash -c rather than -lc: a login shell sources /etc/profile, which resets PATH
# and loses the one set in the image.
podman run --rm --arch arm64 \
  -e TAR_OPTIONS=--no-same-owner \
  -v "$proj":/src:ro,Z \
  -v "$out":/out:Z \
  "$img" bash -c "
    set -e
    export PATH=/opt/flutter/bin:\$PATH
    mkdir -p /work
    tar -C /src --exclude=./build --exclude=./.dart_tool --exclude=./.git -cf - . \
      | tar -C /work -xf -
    cd /work
    flutter build linux --release --dart-define-from-file=$config
    tar czf /out/rackglass-arm64.tar.gz -C build/linux/arm64/release bundle
  " || exit 1

echo "built: $out/rackglass-arm64.tar.gz"
file "$out"/../arm64-out/rackglass-arm64.tar.gz >/dev/null 2>&1
