#!/usr/bin/env bash
# Launch a fresh Nitro instance, provision it, obtain the canonical enclave
# image, run it, and register it permissionlessly. Nothing pre-existing is
# reused. Writes .enclave-session for attest.sh / teardown.sh.
#
# Usage: ./setup.sh [--build]
#   default   download the pre-built EIF from the RELEASE_TAG release
#   --build   build the EIF from source on the host instead (slow; self-verifying)

. "$(cd "$(dirname "$0")" && pwd)/ops-common.sh"

BUILD=""; NO_REGISTER=""
for a in "$@"; do case "$a" in
  --build) BUILD=1 ;;
  --no-register) NO_REGISTER=1 ;;
  *) die "unknown option: $a (use --build and/or --no-register)" ;;
esac; done
# Registering needs sui; a verify-only bring-up (--no-register, for CI) does not.
[ -n "$NO_REGISTER" ] || require_sui_network

# Resolve the EIF source before touching AWS, so a bad RELEASE_TAG fails fast.
if [ -n "$BUILD" ]; then
    EIF_SRC=build
else
    EIF_SRC=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$RELEASE_TAG" \
              | jq -r '.assets[] | select(.name=="nitro.eif") | .browser_download_url')
    [ -n "$EIF_SRC" ] && [ "$EIF_SRC" != null ] \
        || die "no nitro.eif asset on release $RELEASE_TAG (publish one, or use --build)"
fi

log "launching $INSTANCE_TYPE from $AMI_ID"
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
    --enclave-options 'Enabled=true' --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=sv-enclave}]' \
    --query 'Instances[].InstanceId' --output text) || die "launch failed"
[ -n "$INSTANCE_ID" ] || die "launch returned no instance id"
# Record the instance immediately, so teardown can always clean up.
printf 'INSTANCE_ID=%s\n' "$INSTANCE_ID" >"$SESSION"
log "launched $INSTANCE_ID; waiting for it to run"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
IP=$(host_ip)
log "running at $IP; waiting for sshd"
for _ in $(seq 1 40); do hssh true 2>/dev/null && break; sleep 5; done
hssh true 2>/dev/null || die "host $IP not reachable over ssh"

log "provisioning and bringing up the enclave (EIF: ${EIF_SRC%%:*})"
hssh "bash -s -- $MEMORY_MIB $CPU_COUNT $PCR0 $PCR1 $PCR2 '$EIF_SRC' $REPO '$RELEASE_TAG'" <<'REMOTE'
set -e
MEM=$1; CPUS=$2; XP0=$3; XP1=$4; XP2=$5; EIF_SRC=$6; REPO=$7; TAG=$8

# --- provision the host (running an EIF needs only nitro-cli + socat) ---
sudo yum install -y -q aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel socat jq >/dev/null 2>&1
sudo sed -ri "s/^(\s*memory_mib\s*:\s*).*/\1$MEM/"  /etc/nitro_enclaves/allocator.yaml
sudo sed -ri "s/^(\s*cpu_count\s*:\s*).*/\1$CPUS/"   /etc/nitro_enclaves/allocator.yaml
for h in github.com raw.githubusercontent.com fullnode.testnet.sui.io release-assets.githubusercontent.com fullnode.mainnet.sui.io; do
  grep -q "address: $h" /etc/nitro_enclaves/vsock-proxy.yaml \
    || echo "- {address: $h, port: 443}" | sudo tee -a /etc/nitro_enclaves/vsock-proxy.yaml >/dev/null
done
sudo systemctl enable --now nitro-enclaves-allocator.service
sudo systemctl restart nitro-enclaves-allocator.service; sleep 3
declare -A EG=( [8101]=github.com [8102]=raw.githubusercontent.com [8103]=fullnode.testnet.sui.io [8104]=release-assets.githubusercontent.com [8105]=fullnode.mainnet.sui.io )
for p in "${!EG[@]}"; do
  pgrep -f "vsock-proxy $p " >/dev/null \
    || setsid vsock-proxy "$p" "${EG[$p]}" 443 --config /etc/nitro_enclaves/vsock-proxy.yaml </dev/null >"/tmp/vsock-$p.log" 2>&1 &
done

# --- obtain the EIF ---
mkdir -p ~/enclave && cd ~/enclave
if [ "$EIF_SRC" = build ]; then
  echo "building the EIF from source (slow)..."
  sudo yum install -y -q docker git make >/dev/null 2>&1
  sudo systemctl enable --now docker
  rm -rf repo && git clone -q --depth 1 --branch "$TAG" "https://github.com/$REPO.git" repo
  ( cd repo && sudo make verifier >/dev/null && sudo make ENCLAVE_APP=source-verification >/dev/null )
  sudo cp repo/out/nitro.eif nitro.eif && sudo chown "$USER" nitro.eif
else
  echo "downloading the pre-built EIF..."
  curl -fL "$EIF_SRC" -o nitro.eif
fi
echo '{}' > secrets.json

# --- gate: the image must reproduce the recorded measurements ---
# nitro-cli opens /var/log/nitro_enclaves on every command, so run it via sudo
# (and ensure the dir) or describe-eif fails (E19) on a freshly provisioned host.
sudo mkdir -p /var/log/nitro_enclaves
eif=$(sudo nitro-cli describe-eif --eif-path nitro.eif)
for n in 0 1 2; do
  got=$(echo "$eif" | jq -r ".Measurements.PCR$n"); exp=$(eval echo \$XP$n)
  [ "$got" = "$exp" ] || { echo "PCR$n mismatch: image $got, config $exp -- refusing to register" >&2; exit 1; }
done
echo "PCRs match the recorded EnclaveConfig"

# --- run non-debug, feed secrets, expose :3000 ---
# The allocator reserves the enclave memory as 1G hugepages asynchronously after
# its restart; run-enclave started before that finishes hangs and can wedge the
# CPU pool. Wait for the reservation to land, then run once.
sudo mkdir -p /var/log/nitro_enclaves
need=$(( MEM / 1024 ))
for _ in $(seq 1 60); do
  got=$(cat /sys/devices/system/node/node*/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null | awk '{s+=$1} END{print s+0}')
  [ "${got:-0}" -ge "$need" ] && break
  sleep 2
done
echo "allocator reserved ${got:-0}/$need x 1G hugepages"
sudo nitro-cli terminate-enclave --all >/dev/null 2>&1 || true
sudo timeout 90 nitro-cli run-enclave --cpu-count "$CPUS" --memory "$MEM" --eif-path nitro.eif >/dev/null 2>&1 || true
CID=$(sudo nitro-cli describe-enclaves | jq -r '.[0].EnclaveCID // empty')
[ -n "$CID" ] || { echo "enclave failed to start" >&2; exit 1; }
echo "enclave running, CID=$CID"
# The enclave starts listening on 7777 for secrets a moment after boot; retry.
sleep 5
for _ in $(seq 1 10); do
  cat secrets.json | timeout 10 socat - "VSOCK-CONNECT:$CID:7777" 2>/dev/null && break
  sleep 3
done
pkill -f 'TCP4-LISTEN:3000' 2>/dev/null || true
# setsid + </dev/null fully detach these background helpers; otherwise they hold
# this ssh session's channel open and setup hangs after "enclave serving".
setsid socat TCP4-LISTEN:3000,reuseaddr,fork "VSOCK-CONNECT:$CID:3000" </dev/null >/tmp/fwd.log 2>&1 &
# After secrets, the server mounts its tmpfs and comes up; poll until it serves.
len=0
for _ in $(seq 1 20); do
  len=$(curl -s --max-time 10 localhost:3000/get_attestation 2>/dev/null | jq -r '.attestation // empty' | wc -c)
  [ "$len" -gt 100 ] && break
  sleep 3
done
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

if [ -n "$NO_REGISTER" ]; then
  { printf 'INSTANCE_ID=%s\n' "$INSTANCE_ID"
    printf 'ENCLAVE_URL=%s\n' "$ENCLAVE_URL"; } >"$SESSION"
  log "enclave serving at $ENCLAVE_URL (not registered)"
  log "session -> $SESSION.  Next: ./attest.sh <package-dir> --no-attest"
else
  log "registering the enclave (no Cap, permissionless)"
  out=$(bash "$HERE/register_enclave.sh" "$ENCLAVE_PKG" "$APP_PKG" "$CONFIG_ID" "$ENCLAVE_URL" "$MODULE" "$OTW")
  # The created Enclave object's id, robust to sui's ID:/ObjectID: table variants.
  EOBJ=$(printf '%s\n' "$out" | grep -B3 "::enclave::Enclave<" | grep -oE "0x[0-9a-f]{64}" | head -1)
  [ -n "$EOBJ" ] || { echo "$out" | tail -20; die "no registered Enclave object found in the output"; }
  { printf 'INSTANCE_ID=%s\n' "$INSTANCE_ID"
    printf 'ENCLAVE_URL=%s\n' "$ENCLAVE_URL"
    printf 'ENCLAVE_OBJECT_ID=%s\n' "$EOBJ"; } >"$SESSION"
  log "registered Enclave $EOBJ"
  log "session -> $SESSION.  Next: ./attest.sh <package-dir>"
fi
