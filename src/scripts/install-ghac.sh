#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Supply-chain note (mirrors install.sh's own -- see that file's header for
# the full rationale on why a pinned commit + checksum, not a mutable ref)
#
# ghac has no upstream GitHub Releases of its own (see tools/ghac/README.md,
# "Known interim limitation"): the binaries fetched here are this same
# repo's own dist/ghac/ at a pinned, immutable commit, fetched over HTTPS
# from raw.githubusercontent.com and verified against a pinned SHA256 before
# ever being chmod +x'd and executed. If tools/ghac is rebuilt
# (tools/ghac/build.sh), a human must bump GHAC_PINNED_COMMIT to a pushed
# commit containing the new binaries AND update both SHA256 values below to
# match, together, in the same change.
# ---------------------------------------------------------------------------
GHAC_PINNED_COMMIT="c052d87b84b5ff421897fe68528d193c30d35140"
GHAC_AMD64_SHA256="25ee41b97609791d96fe7c6860446b63c18f54ceba2a58d63efc175d082f63c4"
GHAC_ARM64_SHA256="a90c2fe1b6003469b112e4dbd5d8352e7eb03f186133a928ee7ab733214824cc"

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "Error: neither sha256sum nor shasum is available to verify the ghac binary." >&2
        exit 1
    fi
}

case "$(uname -m)" in
    x86_64 | amd64)
        GHAC_ARCH="amd64"
        GHAC_SHA256="${GHAC_AMD64_SHA256}"
        ;;
    aarch64 | arm64)
        GHAC_ARCH="arm64"
        GHAC_SHA256="${GHAC_ARM64_SHA256}"
        ;;
    *)
        echo "Error: ghac has no prebuilt binary for architecture '$(uname -m)'. Only linux/amd64 and linux/arm64 are built today -- see tools/ghac/build.sh to add another." >&2
        exit 1
        ;;
esac

GHAC_BIN_DIR="${ORB_VAL_BIN_DIR:-/home/circleci/bin}"
mkdir -p "${GHAC_BIN_DIR}"
GHAC_DEST="${GHAC_BIN_DIR}/ghac"

if [[ -x "${GHAC_DEST}" ]] && "${GHAC_DEST}" --help > /dev/null 2>&1; then
    echo "ghac already present at ${GHAC_DEST}; skipping fetch."
    exit 0
fi

GHAC_URL="https://raw.githubusercontent.com/CircleCI-Labs/act-orb/${GHAC_PINNED_COMMIT}/dist/ghac/ghac_linux_${GHAC_ARCH}"
GHAC_TMP="$(mktemp)"
trap 'rm -f "${GHAC_TMP}"' EXIT

echo "Fetching ghac (linux/${GHAC_ARCH}, pinned commit ${GHAC_PINNED_COMMIT})..."
curl --proto '=https' --tlsv1.2 -sSf --retry 6 --retry-all-errors \
    -o "${GHAC_TMP}" "${GHAC_URL}"

ACTUAL_SHA256="$(sha256_of "${GHAC_TMP}")"
if [[ "${ACTUAL_SHA256}" != "${GHAC_SHA256}" ]]; then
    echo "Error: ghac (linux/${GHAC_ARCH}, pinned commit ${GHAC_PINNED_COMMIT}) failed checksum verification." >&2
    echo "  expected: ${GHAC_SHA256}" >&2
    echo "  got:      ${ACTUAL_SHA256}" >&2
    echo "Refusing to install an unverified binary." >&2
    exit 1
fi
echo "ghac checksum verified (sha256:${ACTUAL_SHA256})."

install -m 0755 "${GHAC_TMP}" "${GHAC_DEST}"
echo "Installed ghac to ${GHAC_DEST}"
