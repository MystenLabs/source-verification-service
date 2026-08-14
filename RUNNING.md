# Running your own source-verification enclave

Source-verification attestations are produced by a [Nautilus][nautilus] enclave
running the canonical image defined by this repository. Because that image builds
reproducibly, **anyone can run it** — you register it permissionlessly and produce
attestations of the same trusted type. You do **not** publish a package of your
own; the value is producing attestations of *this* package's type, which explorers
like MVR trust.

This document describes how to stand that enclave up and produce attestations,
using the `setup.sh` / `attest.sh` / `teardown.sh` scripts.

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

- An AWS account with permission to launch EC2 (Nitro Enclaves-capable).
- The `sui` CLI configured for the network you are attesting on, with a funded
  address for gas.
- A clone of this repository. Copy `enclave-ops.conf.example` to
  `enclave-ops.conf` and fill in your AWS launch parameters (region, a stock
  Amazon Linux 2023 AMI, an `m5.2xlarge`, an EC2 key pair, a subnet, and a
  security group allowing SSH). On-chain ids are read from
  `addresses.<network>.json`.

## 3. `./setup.sh` — stand up and register the enclave

Launches a fresh Nitro instance, provisions it, and **downloads** the canonical
enclave image from the release (`--build` builds it from source instead). It
asserts the image's PCRs match the on-chain `EnclaveConfig` before registering —
if they do not, it stops. Then it runs the enclave, exposes it over an SSH tunnel,
and registers it permissionlessly (no `Cap`, no publish). The enclave needs **12G**
of memory for its verification scratch, so the instance must be an `m5.2xlarge` or
larger.

`--no-register` brings the enclave up without registering — enough to verify a
package without any on-chain writes or a funded key.

## 4. `./attest.sh <package-dir>` — verify a package and record the attestation

Point it at a checkout of the package, at the pushed commit you want attested. It
reads the git coordinates, asks the enclave to verify that commit, and records the
`Attestation<SourceVerification>`. `--no-attest` stops at the signed response,
which is itself the product; recording it on-chain is optional.

## 5. `./teardown.sh` — delete and release

Deletes the enclave object (it is ephemeral — a fresh key every boot) and
terminates the instance, leaving nothing running and no storage rent.

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
