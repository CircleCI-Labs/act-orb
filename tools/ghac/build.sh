#!/bin/bash
# Rebuilds the ghac binaries committed at dist/ghac/. See README.md's
# "Rebuilding" section — after running this, the pinned SHA256 values in
# src/scripts/install-ghac.sh must be updated to match, and
# GHAC_PINNED_COMMIT must be bumped to a pushed commit that contains the
# new binaries.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
OUT_DIR="../../dist/ghac"
mkdir -p "${OUT_DIR}"

for arch in amd64 arm64; do
    echo "Building linux/${arch}..."
    GOOS=linux GOARCH="${arch}" CGO_ENABLED=0 go build -ldflags="-s -w" \
        -o "${OUT_DIR}/ghac_linux_${arch}" ./cmd/ghac
done

echo
echo "Built. New checksums:"
shasum -a 256 "${OUT_DIR}"/ghac_linux_amd64 "${OUT_DIR}"/ghac_linux_arm64
