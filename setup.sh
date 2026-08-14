#!/usr/bin/env bash
# Start the host, stand up the enclave, and register it permissionlessly.
# Writes .enclave-session for attest.sh / teardown.sh to consume.
#
# Assumes the host is already provisioned (Nitro CLI, docker, allocator, the
# egress allowlist in vsock-proxy.yaml, and a clone of this repo with the EIF
# built). Provisioning a fresh instance is not yet automated -- see RUNNING.md.

. "$(cd "$(dirname "$0")" && pwd)/ops-common.sh"

require_sui_network

log "starting instance $INSTANCE_ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
IP=$(host_ip)
log "instance running at $IP; waiting for sshd"
for _ in $(seq 1 30); do hssh true 2>/dev/null && break; sleep 5; done
hssh true 2>/dev/null || die "host $IP not reachable over ssh"

log "bringing up the enclave (egress proxies, allocator, run, expose)"
hssh "bash -s -- $MEMORY_MIB $CPU_COUNT $PCR0 $PCR1 $PCR2 $HOST_REPO" <<'REMOTE'
set -e
MEM=$1; CPUS=$2; XP0=$3; XP1=$4; XP2=$5; REPO=$6
cd "$HOME/$REPO" 2>/dev/null || { echo "repo ~/$REPO not on host; provision it first" >&2; exit 1; }
[ -f out/nitro.eif ] || { echo "building EIF (reproducible, slow)..."; make >/dev/null; }

# Refuse to register an image that is not the canonical one.
eif=$(nitro-cli describe-eif --eif-path out/nitro.eif)
for n in 0 1 2; do
  got=$(echo "$eif" | jq -r ".Measurements.PCR$n"); exp=$(eval echo \$XP$n)
  [ "$got" = "$exp" ] || { echo "PCR$n mismatch: built $got, config $exp -- refusing to register" >&2; exit 1; }
done
echo "PCRs match the recorded EnclaveConfig"

# The allocator must have at least the enclave's memory (fixes the 3072 default).
cur=$(grep -E '^\s*memory_mib' /etc/nitro_enclaves/allocator.yaml | grep -oE '[0-9]+' | head -1)
if [ "${cur:-0}" -lt "$MEM" ]; then
  echo "raising allocator memory ${cur:-?} -> $MEM MiB"
  sudo sed -ri "s/^(\s*memory_mib\s*:\s*).*/\1$MEM/" /etc/nitro_enclaves/allocator.yaml
  sudo systemctl restart nitro-enclaves-allocator.service; sleep 3
fi

# All five egress proxies (user-data only starts three); idempotent.
declare -A EG=( [8101]=github.com [8102]=raw.githubusercontent.com [8103]=fullnode.testnet.sui.io [8104]=release-assets.githubusercontent.com [8105]=fullnode.mainnet.sui.io )
for p in "${!EG[@]}"; do
  pgrep -f "vsock-proxy $p " >/dev/null || \
    nohup vsock-proxy "$p" "${EG[$p]}" 443 --config /etc/nitro_enclaves/vsock-proxy.yaml >"/tmp/vsock-$p.log" 2>&1 &
done
sleep 1

# Run the enclave non-debug (real PCRs), then feed it secrets and expose :3000.
sudo nitro-cli terminate-enclave --all >/dev/null 2>&1 || true
sudo nitro-cli run-enclave --cpu-count "$CPUS" --memory "$MEM" --eif-path out/nitro.eif >/dev/null
CID=$(sudo nitro-cli describe-enclaves | jq -r '.[0].EnclaveCID')
echo "enclave running, CID=$CID"
sleep 8
cat secrets.json | timeout 10 socat - "VSOCK-CONNECT:$CID:7777"
pkill -f 'TCP4-LISTEN:3000' 2>/dev/null || true
nohup socat TCP4-LISTEN:3000,reuseaddr,fork "VSOCK-CONNECT:$CID:3000" >/tmp/fwd.log 2>&1 &
sleep 10
len=$(curl -s --max-time 15 localhost:3000/get_attestation | jq -r '.attestation' | wc -c)
[ "$len" -gt 100 ] || { echo "enclave not serving (attestation length $len)" >&2; exit 1; }
echo "enclave serving (attestation length $len)"
REMOTE

log "opening tunnel localhost:$LOCAL_PORT -> enclave :3000"
pkill -f "$LOCAL_PORT:localhost:3000" 2>/dev/null || true
ssh -f -N -L "$LOCAL_PORT:localhost:3000" -i "$SSH_KEY" -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new "$SSH_USER@$IP"
sleep 2
ENCLAVE_URL="http://localhost:$LOCAL_PORT"
curl -sf --max-time 15 "$ENCLAVE_URL/get_attestation" >/dev/null || die "enclave not reachable through the tunnel"

log "registering the enclave (no Cap, permissionless)"
out=$(bash "$HERE/register_enclave.sh" "$ENCLAVE_PKG" "$APP_PKG" "$CONFIG_ID" "$ENCLAVE_URL" "$MODULE" "$OTW")
EOBJ=$(echo "$out" | awk '/ObjectID:/{id=$3} /::enclave::Enclave</{print id; exit}')
[ -n "$EOBJ" ] || { echo "$out" | tail -20; die "no registered Enclave object found in the output"; }

printf 'ENCLAVE_URL=%s\nENCLAVE_OBJECT_ID=%s\n' "$ENCLAVE_URL" "$EOBJ" >"$SESSION"
log "registered Enclave $EOBJ"
log "session -> $SESSION.  Next: ./attest.sh <package-dir>"
