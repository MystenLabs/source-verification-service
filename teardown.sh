#!/usr/bin/env bash
# Delete the enclave object and terminate the instance setup created.
# Usage: ./teardown.sh
#
# setup always launches a fresh instance, so there is nothing to preserve:
# teardown terminates it, leaving no compute and no storage rent.

. "$(cd "$(dirname "$0")" && pwd)/ops-common.sh"

[ -f "$SESSION" ] || die "no session (.enclave-session); nothing to tear down"
# shellcheck source=/dev/null
. "$SESSION"   # INSTANCE_ID, ENCLAVE_URL, ENCLAVE_OBJECT_ID

# 1. Delete the on-chain enclave object we registered (dead once torn down).
if [ -n "${ENCLAVE_OBJECT_ID:-}" ]; then
    require_sui_network
    log "deleting enclave object $ENCLAVE_OBJECT_ID"
    sui client call --package "$ENCLAVE_PKG" --module enclave \
        --function deploy_old_enclave_by_owner \
        --type-args "$APP_PKG::$MODULE::$OTW" \
        --args "$ENCLAVE_OBJECT_ID" --gas-budget 100000000 >/dev/null \
      && log "enclave object deleted" \
      || log "could not delete enclave object (already gone?); continuing"
fi

# 2. Close the tunnel.
pkill -f "$LOCAL_PORT:localhost:3000" 2>/dev/null || true

# 3. Terminate the instance (this also kills the enclave running on it).
if [ -n "${INSTANCE_ID:-}" ]; then
    log "terminating instance $INSTANCE_ID"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null \
      && log "instance terminating" \
      || log "could not terminate $INSTANCE_ID (check the console)"
fi

rm -f "$SESSION"
log "teardown complete"
