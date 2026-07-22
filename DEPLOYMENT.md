# Testnet deployment

The first end-to-end deployment, recorded so the objects can be found and the
enclave image reproduced. Superseded values are replaced rather than appended;
git history is the record of what came before.

## Packages

| | |
| --- | --- |
| `enclave` (vendored) | `0x5eb3bbb4325e2455cdeb34c3321749cf66eab7028b45456ff6124aa80d71cc1f` |
| `source_verification` | `0xa46952734d2c5b96fd06c42512542a84f64e9af7c09371efc24880ed9f35bba9` |
| `attestations` (Mysten's, linked) | `0x6e0e1141d77448253ab434b008a01259e81c5c31bd1cdac8922a5256da690c09` |

Addresses are also in each package's `Published.toml`, which is what the package
system reads; the table is for humans.

## Objects

| | |
| --- | --- |
| `EnclaveConfig<SourceVerifier>` (shared) | `0xd8ff4ceab179600cd429a00c40567c4f79b50854c4da303dfbc837053128e0c9` |
| `Enclave<SourceVerifier>` (shared) | `0x42b8cdceaf133a0a38c7d2ee281ae64ee50ba0695600f2fcc595489b898c7367` |
| `Cap<SourceVerifier>` | `0x5d7cb97ad15b81b5fc8a751018b30834d805150e482cbb5a291b18519f2dd225` |
| `UpgradeCap` (source_verification) | `0x280cc92e3dbed614caf30295050efeb6234e119061cb357652bb845702e74bfa` |
| `attestations::Registry` (shared) | `0x5a8a789c0385d5e891519612a7d3d8ab36f1d9fc03d63cdabf1cefb3d848b568` |

The `Cap` and the two upgrade capabilities are the three that can each
independently forge an attestation; see [DESIGN.md](DESIGN.md#trust-roots). They
are held by a single address here because this is a test deployment. A real one
puts them in a multisig.

## Enclave image

```
PCR0  928da0dc77eb59edfc53d1224245ffe922ce4544b50cb8ff067a11d5676885d01983575b9943ebb9b874523dfbe30c74
PCR1  928da0dc77eb59edfc53d1224245ffe922ce4544b50cb8ff067a11d5676885d01983575b9943ebb9b874523dfbe30c74
PCR2  21b9efbc184807662e966d34f390821309eeac6802309798826296bf3e8bec7c10edb30948c90ba67310f7b964fc500a
```

PCR0 and PCR1 are what bind the image. PCR2 has been identical across every build
regardless of contents, so it is pinned but proves nothing.

These are compiled into `source_verification.move` and were set at publish. A new
image is rolled out with `enclave::update_pcrs` using the `Cap`, not by
republishing.

The EIF is 215 MB and its measurements depend on every digest pinned in the
`Containerfile` and on `VERIFIER_SHA256` in the `Makefile`. Changing any of them
changes the PCRs, which is the point.

## Finding attestations

An `Attestation<T>` is owned by an address derived from the package it is about,
not by whoever submitted it. So every attestation for a package is found by
listing that address's objects — no event scanning, and no dependence on who paid
the gas.

The first attestation recorded by this deployment:

| | |
| --- | --- |
| Attestation | `0x01093888ddab82931406b5153a57d8ee9d2768c90eff57818e35489e220cd0ec` |
| Owner (derived) | `0x405cc60ce6fd586d1c7f451b852a258bc20df419039ae709ac5c1fc1f3e6b59c` |
| Subject | the `attestations` package itself, `0x6e0e1141…` |
| Source | `github.com/MystenLabs/attestations` @ `4729389c`, `packages/attestations` |
| Rebuilt with | sui 1.72.2, sha256 `856000be173a9e9bc1fbecac9554fe107d1d2eac963ac29e9369b1af381f3555` |

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
