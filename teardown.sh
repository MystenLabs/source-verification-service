#!/usr/bin/env bash
# Delete the enclave object, terminate the enclave, and release the instance.
# Usage: ./teardown.sh [--keep-disk]
#
# Default terminates the instance so nothing accrues storage rent. --keep-disk
# stops it instead, preserving the provisioned volume for a fast next setup
# (convenient during development; you keep paying for the EBS volume).

. "$(cd "$(dirname "$0")" && pwd)/ops-common.sh"

KEEP=""; [ "${1:-}" = "--keep-disk" ] && KEEP=1

# 1. Delete the on-chain enclave object we registered (dead once torn down).
if [ -f "$SESSION" ]; then
    # shellcheck source=/dev/null
    . "$SESSION"
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
fi

# 2. Stop the tunnel and terminate the running enclave on the host.
pkill -f "$LOCAL_PORT:localhost:3000" 2>/dev/null || true
state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[].Instances[].State.Name' --output text 2>/dev/null)
if [ "$state" = "running" ]; then
    hssh "sudo nitro-cli terminate-enclave --all >/dev/null 2>&1 || true; pkill -f 'TCP4-LISTEN:3000' 2>/dev/null || true" 2>/dev/null || true
fi

# 3. Release the instance.
rm -f "$SESSION"
if [ -n "$KEEP" ]; then
    log "stopping instance $INSTANCE_ID (disk kept for next setup)"
    aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
else
    log "terminating instance $INSTANCE_ID (no storage rent)"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
fi
log "teardown complete"
