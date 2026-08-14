# Running your own source-verification enclave

Source-verification attestations are produced by a [Nautilus][nautilus] enclave
running the canonical image defined by this repository. Because that image builds
reproducibly, **anyone can run it** — you register it permissionlessly and produce
attestations of the same trusted type. You do **not** publish a package of your
own; the value is producing attestations of *this* package's type, which explorers
like MVR trust.

This document describes how to stand that enclave up and produce attestations.

> **Status:** the turnkey `setup` / `attest` / `teardown` scripts and their exact
> steps are being finalized. This is the intended flow; the underlying pieces exist
> today as `configure_enclave.sh`, `expose_enclave.sh`, `register_enclave.sh`,
> `attest_source.sh`, and `reset_enclave.sh`.

[nautilus]: https://docs.sui.io/sui-stack/nautilus/nautilus-overview

## 1. Make sure your package verifies

Before involving an enclave, confirm the package verifies locally — the enclave
runs exactly this check, so anything that fails here will fail there too:

```shell
sui client verify-source --build-env mainnet
```

If it does not cleanly verify, follow the published guidance on making a package
verifiable: [source-verification troubleshooting][troubleshoot].

[troubleshoot]: https://docs.sui.io/develop/manage-packages/source-verification#when-verification-fails

## 2. Prerequisites

- An AWS account with **Nitro Enclaves** available and permission to launch EC2.
- The `sui` CLI configured for the network you are attesting on, with a funded
  address for gas.
- A clone of this repository.

## 3. `setup` — stand up and register the enclave

`setup` launches a Nitro-capable instance, builds the canonical image
(reproducibly, so its measurements match the on-chain `EnclaveConfig`), runs it,
exposes it, and registers it permissionlessly — no `Cap`, no publish. If the built
measurements do not match the canonical configuration, it stops before registering.

## 4. `attest` — verify a package and record the attestation

Run from inside the package directory (the one with `Move.toml`). It reads the git
coordinates from the checkout, asks the enclave to verify the pushed commit, and —
given the on-chain ids — records the `Attestation<SourceVerification>`. The signed
response is itself the product; recording it on-chain is optional and anyone can do
it later.

## 5. `teardown` — stop and release

`teardown` terminates the enclave and releases the instance.

## Limitations (MVP)

- **GitHub-hosted packages only.** The enclave's egress is a fixed allowlist, so it
  can clone from GitHub and download toolchains from the release mirrors, but not
  from arbitrary git hosts.
- **Older packages may not verify** — see the troubleshooting link above; some
  packages published with older toolchains cannot currently be rebuilt.

## Future work

- Broader / non-GitHub egress.
- A hosted attestation service, so running your own enclave becomes optional.
- [Marlin Oyster][oyster] as an alternative to self-hosting AWS Nitro.

[oyster]: https://www.marlin.org/oyster
