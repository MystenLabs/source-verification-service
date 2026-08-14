#!/usr/bin/env bash
# Verify a package with the running enclave and record the attestation.
# Usage: ./attest.sh <package-dir> [--no-attest]
#
# The package dir is a checkout of the package to verify, at the pushed commit
# you want attested. attest_source.sh reads the git coordinates from it.

. "$(cd "$(dirname "$0")" && pwd)/ops-common.sh"

PKG_DIR="${1:?usage: attest.sh <package-dir> [--no-attest]}"
NO_ATTEST="${2:-}"
[ -d "$PKG_DIR" ] || die "not a directory: $PKG_DIR"

[ -f "$SESSION" ] || die "no enclave session; run ./setup.sh first"
# shellcheck source=/dev/null
. "$SESSION"   # ENCLAVE_URL, ENCLAVE_OBJECT_ID

require_sui_network
curl -sf --max-time 15 "$ENCLAVE_URL/get_attestation" >/dev/null \
    || die "enclave not reachable at $ENCLAVE_URL; run ./setup.sh"

log "attesting $PKG_DIR against $NETWORK via $ENCLAVE_URL"
cd "$PKG_DIR"
ENCLAVE_URL="$ENCLAVE_URL" \
BUILD_ENV="$NETWORK" \
APP_PACKAGE_ID="$APP_PKG" \
ENCLAVE_OBJECT_ID="$ENCLAVE_OBJECT_ID" \
ENCLAVE_CONFIG_ID="$CONFIG_ID" \
ATTESTATION_REGISTRY_ID="$REGISTRY_ID" \
    bash "$HERE/attest_source.sh" $NO_ATTEST
