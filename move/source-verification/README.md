# source_verification

The on-chain half. Verifies an enclave-signed `SourceVerification` and records it
as an `Attestation<SourceVerification>` about the package it describes.

For what an attestation claims and what has to hold for it to be sound, see
[DESIGN.md](../../DESIGN.md). This file covers only how the package works and how
to deploy it.

## The entry point

```move
public fun attest_source(
    registry: ID,
    enclave: &Enclave<SourceVerifier>,
    pkg_id: ID,
    source_hash: vector<u8>,
    git_url: String,
    subdir: String,
    git_sha: String,
    toolchain_version: String,
    toolchain_digest: vector<u8>,
    timestamp_ms: u64,
    signature: vector<u8>,
    ctx: &mut TxContext,
): ID
```

It rebuilds a `SourceVerification` from the supplied fields, checks the signature
against the enclave's registered key under intent scope 0, and calls
`attestations::attest`.

The payload arrives as fields rather than as a struct because a programmable
transaction can supply only primitives and a few special types as pure arguments.
Taking `SourceVerification` by value would make the function uncallable. Rebuilding
it here is also what makes the signature check meaningful: it verifies against
exactly what the caller supplied, so a caller cannot present one payload for
checking and record another.

Any registered `Enclave<SourceVerifier>` is accepted. `register_enclave` is
permissionless, so anyone running the attested image can serve attestations.

## The cross-language byte lock

The signature covers BCS-serialised bytes, so the Move struct and the enclave's
Rust struct must agree exactly on field order and types. Nothing in the compiler
enforces that across languages, so it is pinned by a pair of tests over the same
fixed value:

- `signing_bytes_match_rust` here asserts the exact bytes;
- `signing_bytes` in the enclave application prints them.

If either struct changes, the Move test fails. Regenerate by running the Rust test
and copying the emitted `SIGNING_BYTES_HEX`, and note that the fixed signature in
the other two tests must be regenerated with it.

## Deploying

Publish the vendored `enclave` package first, then this one, and record the object
ids the transactions create:

```shell
sui client publish move/enclave
sui client publish move/source-verification
```

Publishing runs `init`, which mints a `Cap<SourceVerifier>` to the publisher and
shares an `EnclaveConfig<SourceVerifier>` holding the expected PCRs.

The `PCR0`/`PCR1`/`PCR2` constants must match the image being run. They are
compiled in for the initial publish and updatable afterwards by the `Cap` holder
through `enclave::update_pcrs` — which is how a new enclave build is rolled out,
and also how a deployer switches to all-zero PCRs to register a debug-mode enclave
for testing.

`register_source_display` sets up the `Display` for the resulting attestations. It
is one-shot and aborts if called twice.

## Dependencies

`enclave` is vendored locally; see [VENDORED.md](../../VENDORED.md).

`attestations` is pinned to a commit rather than tracking `main`. A moving
dependency would change this package's linkage without any change here, which is
precisely the failure this service exists to detect.
