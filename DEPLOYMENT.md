# Testnet deployment

The first end-to-end deployment, recorded so the objects can be found and the
enclave image reproduced. Superseded values are replaced rather than appended;
git history is the record of what came before.

## Packages

The addresses are in [`addresses.testnet.json`](addresses.testnet.json) (and in each
package's `Published.toml`, which is what the package system reads). What each is:

- **`enclave`** — the vendored `enclave` package.
- **`sourceVerification`** — this service's contract, as `originalId` / `latestId` /
  `version` / `upgradeCap`.
- **`attestations`** — Mysten's `attestations` package, linked.

`source_verification` keeps one lineage: it is *upgraded*, not republished, as the
service evolves, so its original-id and its recorded attestations are stable. The
type is identified by the original-id, so every attestation stays the same type
across upgrades. This is viable because the changes so far have been
upgrade-compatible — including *removing* an `entry` function (a testnet-only
Display migration helper), which the Compatible policy allows for non-`public`
functions.

## Objects

Also in [`addresses.testnet.json`](addresses.testnet.json):

- **`enclaveConfig`** — the shared `EnclaveConfig<SourceVerifier>`.
- **`cap`** — the `enclave::Cap<SourceVerifier>`.
- **`attestationsRegistry`** — the shared `attestations::Registry`.

The `Display<Attestation<SourceVerification>>` is not listed: it is registered for
the current type and found through the Registry's `DisplayCap`.

The `Cap` and the two upgrade capabilities are the three that can each
independently forge an attestation; see [DESIGN.md](DESIGN.md#trust-roots).

## Enclave image

```
PCR0  92b237a89f9721d37f29d342a24683c04082a88edce9199ed30215cd7479c3035a03c541b18d89013e48c91326bcab01
PCR1  92b237a89f9721d37f29d342a24683c04082a88edce9199ed30215cd7479c3035a03c541b18d89013e48c91326bcab01
PCR2  21b9efbc184807662e966d34f390821309eeac6802309798826296bf3e8bec7c10edb30948c90ba67310f7b964fc500a
```

PCR0 and PCR1 are what bind the image.

The PCRs are **not** compiled into the contract — they are deployment data. After
publishing, the `Cap` holder creates the shared `EnclaveConfig` with them:

```shell
sui client call --package "$ENCLAVE_PKG" --module enclave --function create_enclave_config \
    --type-args "$APP_PKG::source_verification::SourceVerifier" \
    --args "$CAP" source-verification 0x4d4412ff…027e7a 0x4d4412ff…027e7a 0x21b9efbc…c500a
```

and rolls out a new image later with `enclave::update_pcrs` on the same `Cap`, no
republish. The EIF is 215 MB and its measurements depend on every digest pinned in
the `Containerfile` and on `VERIFIER_SHA256` in the `Makefile`; changing any of
them changes the PCRs, which is the point.

## Display

Registered, with three fields:

| | |
| --- | --- |
| `name` | `Verified source` |
| `description` | `The source at {data.git_url} ({data.git_sha}), subdirectory {data.subdir}, compiles to the bytecode published at {data.pkg_id}. Rebuilt with sui {data.toolchain_version}. Source hash {data.source_hash}.` |
| `link` | `https://github.com/MystenLabs/source-verification-service` |

`link` points at this service rather than the verified repository. The
attestations conventions define it as the artifact backing the attestation -- an
audit links its report -- and they ask consumers to constrain it to the
attester's known domains, which a requester-supplied `git_url` could not satisfy.

The Display is append-only within a published package: `add_display_field`
refuses a field that is already set, and nothing exposes overwrite, unset or
clear. It is not permanent across publishes, though -- a republish mints a new
`SourceVerification` type and so a fresh Display.

`image_url` is absent because it needs a stable public URL. It can be appended
with `add_display_field`, using the `DisplayCap` above, which
`register_source_display` parked on the Registry.

## Cost

Measured on testnet, not estimated:

| | |
| --- | --- |
| publish `enclave` | 0.0205 SUI |
| publish `source_verification` | 0.0233 SUI |
| `register_enclave` | 0.0157 SUI |
| `attest_source` | 0.0048 SUI |

Registration is the one worth noting. It runs the Nitro attestation native, whose
per-call costs in the protocol config are large enough to suggest single-digit
SUI; the measured cost is three orders of magnitude less. Estimate it with a dry
run rather than from those constants.

## Reproducing

```shell
make verifier SUI_SRC=/path/to/sui   # checks out VERIFIER_REV, asserts VERIFIER_SHA256
make ENCLAVE_APP=source-verification
cat out/nitro.pcrs                    # must match the PCRs above
```

The verifier is built from a pinned revision and checked against a pinned digest
because `cargo build --release` is not guaranteed byte reproducible. Once
`verify-source` appears in a sui release, this step becomes a download of that
release instead — see [DESIGN.md](DESIGN.md#the-verifier-is-the-same-kind-of-artifact).
