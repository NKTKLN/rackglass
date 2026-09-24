#!/bin/bash
# Cross-build rackglass for linux-arm64 (Raspberry Pi, KMS backend) in podman.
#
#   tools/arm64/build.sh [output dir]
#
# Defaults to ./build/arm64-out. Needs only podman: the build runs natively on
# the x64 host, no qemu. The first run builds the image and fetches crates;
# later runs reuse both, plus the cargo target dir, from named volumes.
#
# Configuration is read at runtime on the Pi, so nothing here depends on a
# config file.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
proj=$(cd "$here/../.." && pwd)
out=${1:-$proj/build/arm64-out}
img=rackglass-arm64-cross
target=aarch64-unknown-linux-gnu

mkdir -p "$out"

# --arch amd64 is not redundant: a debian:bookworm pulled once for arm64 (the
# old Flutter build did exactly that) shadows the amd64 one, and the whole
# cross-build then silently runs under qemu at a fraction of the speed.
podman build --arch amd64 -t "$img" -f "$here/Containerfile" "$here" || exit 1

# The source is mounted read-only; build output goes to volumes so a rebuild
# is incremental and the working tree never gets root-owned files in it.
podman run --rm --arch amd64 \
  -v "$proj":/src:ro,Z \
  -v "$out":/out:Z \
  -v rackglass-cargo-registry:/root/.cargo/registry \
  -v rackglass-cargo-target:/target \
  -e CARGO_TARGET_DIR=/target \
  -w /src \
  "$img" bash -c "
    set -e
    cargo build --release --locked --target $target \
      --no-default-features --features kms
    stage=\$(mktemp -d)/rackglass
    mkdir -p \$stage
    cp /target/$target/release/rackglass \$stage/
    cp config.env.example tools/arm64/rackglass.service \$stage/
    tar czf /out/rackglass-arm64.tar.gz -C \$(dirname \$stage) rackglass
  " || exit 1

echo "built: $out/rackglass-arm64.tar.gz"
