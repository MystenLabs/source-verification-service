# Testnet deployment

The first end-to-end deployment, recorded so the objects can be found and the
enclave image reproduced. Superseded values are replaced rather than appended;
git history is the record of what came before.

## Packages

| | |
| --- | --- |
| `enclave` (vendored) | `0x8358708a5f14133d7ca5f1a6c1a48dcdca1ce81c83e448851aec5e6cf03d8def` |
| `source_verification` | original-id `0xcb8431ee…`, latest version `0x270c883b…` |
| `attestations` (Mysten's, linked) | `0x6e0e1141d77448253ab434b008a01259e81c5c31bd1cdac8922a5256da690c09` |

Addresses are also in each package's `Published.toml`, which is what the package
system reads; the table is for humans.

`source_verification` keeps one lineage: it is *upgraded*, not republished, as the
service evolves, so its original-id and its recorded attestations are stable. The
type is identified by the original-id, so every attestation stays the same type
across upgrades. This is viable because the changes so far have been
upgrade-compatible — including *removing* an `entry` function (a testnet-only
Display migration helper), which the Compatible policy allows for non-`public`
functions.

## Objects

| | |
| --- | --- |
| `EnclaveConfig<SourceVerifier>` (shared) | `0xe4da114a4a5e35751cc730dd48c1a0588b27ef3cd35e91ab37bd58d91125cb57` |
| `Enclave<SourceVerifier>` (shared) | `0xd450418a9e185fcec981e29ea34d7ee38eff6d71989cf1f95c0524af8772bbdc` |
| `Cap<SourceVerifier>` | `0x7985f057e3f6df05704cdbb2ec9d943d3965f650ba6912844d4975765e7d721b` |
| `Display<Attestation<SourceVerification>>` (shared) | registered for the current type; find it via the Registry's `DisplayCap` |
| `attestations::Registry` (shared) | `0x5a8a789c0385d5e891519612a7d3d8ab36f1d9fc03d63cdabf1cefb3d848b568` |

The `Cap` and the two upgrade capabilities are the three that can each
independently forge an attestation; see [DESIGN.md](DESIGN.md#trust-roots). They
are held by a single address here because this is a test deployment. A real one
puts them in a multisig.

## Enclave image

```
PCR0  92b237a89f9721d37f29d342a24683c04082a88edce9199ed30215cd7479c3035a03c541b18d89013e48c91326bcab01
PCR1  92b237a89f9721d37f29d342a24683c04082a88edce9199ed30215cd7479c3035a03c541b18d89013e48c91326bcab01
PCR2  21b9efbc184807662e966d34f390821309eeac6802309798826296bf3e8bec7c10edb30948c90ba67310f7b964fc500a
```

PCR0 and PCR1 are what bind the image. PCR2 has been identical across every build
regardless of contents, so it is pinned but proves nothing.

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

## Finding attestations

An `Attestation<T>` is owned by an address derived from the package it is about,
not by whoever submitted it. So every attestation for a package is found by
listing that address's objects — no event scanning, and no dependence on who paid
the gas.

| | |
| --- | --- |
| Attestation | `0x52f2113eec38f0e785c18afd154568aefc5a3267e503755daefcdade95acdb37` |
| Owner (derived) | `0x405cc60ce6fd586d1c7f451b852a258bc20df419039ae709ac5c1fc1f3e6b59c` |
| Subject | the `attestations` package itself, `0x6e0e1141…` |
| Source | `github.com/MystenLabs/attestations` @ `4729389c`, `packages/attestations` |
| Rebuilt with | sui 1.72.2, sha256 `856000be173a9e9bc1fbecac9554fe107d1d2eac963ac29e9369b1af381f3555` |

It renders through the Display as:

> **Verified source**
> The source at https://github.com/MystenLabs/attestations.git
> (4729389cd5ef76d376a2733ec06d9b051c80c419), subdirectory packages/attestations,
> compiles to the bytecode published at 0x6e0e1141…. Rebuilt with sui 1.72.2.
> Source hash cf6f3499ea70df70437ee84603127165d68106b8f2e1cd7be517294e23276dc4.

An earlier attestation, `0x01093888ddab82931406b5153a57d8ee9d2768c90eff57818e35489e220cd0ec`,
was recorded against a superseded publish whose payload carried the digests as
`vector<u8>`. It has the same derived owner, since that address depends only on
the subject.

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
