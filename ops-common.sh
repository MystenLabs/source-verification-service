# Shared configuration and helpers for the source-verification enclave scripts.
# Sourced by setup.sh, attest.sh, and teardown.sh -- not run directly.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- operator config --------------------------------------------------------
# Copy enclave-ops.conf.example to enclave-ops.conf and edit it.
CONF="${ENCLAVE_OPS_CONF:-$HERE/enclave-ops.conf}"
[ -f "$CONF" ] || die "missing config: cp enclave-ops.conf.example enclave-ops.conf and edit it"
# shellcheck source=/dev/null
. "$CONF"

: "${INSTANCE_ID:?set INSTANCE_ID in enclave-ops.conf}"
: "${REGION:?set REGION in enclave-ops.conf}"
: "${SSH_KEY:?set SSH_KEY in enclave-ops.conf}"
SSH_USER="${SSH_USER:-ec2-user}"
HOST_REPO="${HOST_REPO:-source-verification-service}"
NETWORK="${NETWORK:-testnet}"
CPU_COUNT="${CPU_COUNT:-2}"
MEMORY_MIB="${MEMORY_MIB:-8192}"
LOCAL_PORT="${LOCAL_PORT:-3000}"

# --- on-chain ids, read from the committed deployment record ----------------
# The enclave object is deliberately absent: it is ephemeral (a fresh keypair
# every boot), minted by setup and recorded in the session file below.
ADDR="$HERE/addresses.$NETWORK.json"
[ -f "$ADDR" ] || die "missing $ADDR"
ENCLAVE_PKG=$(jq -er '.packages.enclave' "$ADDR")            || die "no packages.enclave in $ADDR"
APP_PKG=$(jq -er '.packages.sourceVerification.latestId' "$ADDR") || die "no sourceVerification.latestId in $ADDR"
CONFIG_ID=$(jq -er '.objects.enclaveConfig' "$ADDR")        || die "no objects.enclaveConfig in $ADDR"
REGISTRY_ID=$(jq -er '.objects.attestationsRegistry' "$ADDR") || die "no objects.attestationsRegistry in $ADDR"
PCR0=$(jq -er '.pcrs.pcr0' "$ADDR"); PCR1=$(jq -er '.pcrs.pcr1' "$ADDR"); PCR2=$(jq -er '.pcrs.pcr2' "$ADDR")
MODULE=source_verification
OTW=SourceVerifier

# Written by setup, read by attest/teardown. Holds the ephemeral enclave object
# and the local URL the enclave is tunneled to.
SESSION="$HERE/.enclave-session"

# --- host access ------------------------------------------------------------
# The instance's public IP changes on every start, so it is always looked up.
host_ip() {
    aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[].Instances[].PublicIpAddress' --output text 2>/dev/null
}

hssh() {
    ssh -i "$SSH_KEY" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "$SSH_USER@$(host_ip)" "$@"
}

# The sui CLI records the attestation and deletes the enclave object; it must be
# pointed at the target network with a funded address. Rather than silently
# switch the operator's global env, refuse and tell them how.
require_sui_network() {
    command -v sui >/dev/null || die "sui CLI not found in PATH"
    local cur; cur=$(sui client active-env 2>/dev/null || true)
    [ "$cur" = "$NETWORK" ] || die "sui active-env is '$cur'; switch first:  sui client switch --env $NETWORK"
}
