# Vendored from Nautilus

This repository vendors a subset of [MystenLabs/nautilus](https://github.com/MystenLabs/nautilus)
rather than forking it or depending on it.

**Upstream commit: `048bae1dc2715bb201b424e3febd0056cba8dfe8`**

Vendoring is how Nautilus is meant to be used. Upstream, the `enclave` Move
package is an unpublished template; each deployer vendors it and publishes their
own copy — ours is recorded in `move/enclave/Published.toml`. Its manifest is
new-style (edition `2024`, no hard-coded `[addresses]` — the address binds by
name): the upstream template still ships it in old-style syntax, and vendoring it
here is the point at which that is modernized, so a new package is not defining
old-style syntax. The Rust server is likewise a template to be modified, not a
library to depend on.

## Verifying this subset

The files below are **byte-identical** to the upstream commit, so most of this
import can be checked mechanically rather than read. A handful are modified for
this service; those are listed under [Local modifications](#local-modifications)
and excluded here.

Byte-identity is provenance, not endorsement: upstream Nautilus is itself
unaudited and provided as-is under its licence, so matching it establishes *what*
was vendored, not that the vendored code is correct.

```shell
git clone https://github.com/MystenLabs/nautilus /tmp/nautilus
git -C /tmp/nautilus checkout 048bae1dc2715bb201b424e3febd0056cba8dfe8

for f in LICENSE rust-toolchain.toml \
         src/nautilus-server/src/common.rs \
         src/nautilus-server/traffic_forwarder.py \
         move/enclave/Move.toml \
         configure_enclave.sh expose_enclave.sh register_enclave.sh reset_enclave.sh; do
    diff -q "/tmp/nautilus/$f" "$f" || echo "DIFFERS: $f"
done
```

Modified files (`Containerfile`, `Makefile`, `run.sh`, the two `Cargo` files,
`lib.rs`, `main.rs`, `enclave.move`) are best reviewed as diffs against the same
upstream commit — `git diff` against `/tmp/nautilus/<f>` shows exactly what this
service changed.

## What was taken

| Path | Why |
| --- | --- |
| `move/enclave/` | `Enclave<T>`, `EnclaveConfig<T>`, `Cap<T>`, permissionless `register_enclave`, `verify_signature`. The on-chain half of the attestation scheme. |
| `src/nautilus-server/src/{lib,main,common}.rs` | Server skeleton: ephemeral key generation, `/get_attestation`, `/health_check`, HTTP setup. |
| `src/nautilus-server/{Cargo.toml,Cargo.lock}` | Dependency set, including the pinned `fastcrypto` revision. |
| `src/nautilus-server/run.sh` | Enclave init: loopback, `/etc/hosts`, traffic forwarders, secrets over vsock. |
| `src/nautilus-server/traffic_forwarder.py` | The enclave side of egress; pairs with `vsock-proxy` on the host. |
| `Containerfile`, `Makefile` | Reproducible EIF build from StageX images. |
| `configure_enclave.sh`, `expose_enclave.sh`, `register_enclave.sh`, `reset_enclave.sh` | Deployment. |
| `rust-toolchain.toml`, `LICENSE` | Toolchain pin; Apache 2.0, retained as required. |

## What was left behind

The example applications, which are the bulk of the upstream tree and none of
which this service uses:

- `src/nautilus-server/src/apps/{weather,twitter,seal}-example/`
- `move/{weather-example,twitter-example,seal-policy}/`
- `update_weather.sh`, `update.sh`, `user-data.sh`

Upstream documentation — `UsingNautilus.md`, `Design.md`, `flows.png` — is not
carried either. It documents Nautilus; this repository documents this service,
and a stale copy would be worse than a pointer to the original.

`deny.toml` and `scripts/` are the upstream repository's CI configuration and are
replaced by this repository's own.

## Local modifications

Some vendored files are changed for this service. Each is a diff against the
upstream commit, reviewable on its own:

- **`src/nautilus-server/src/lib.rs`, `main.rs`** — reduced to the single app this
  service ships. The upstream template carries a multi-app `#[cfg]` structure, an
  `api_key` in `AppState`, and a seal host-init server; none apply here, and their
  example modules were never vendored, so the references are removed.
- **`src/nautilus-server/Cargo.toml`, `Cargo.lock`** — drops the example-only
  features and their optional dependencies (`regex`, `sui-crypto`,
  `sui-sdk-types`, `seal-sdk`), and defaults the `source-verification` feature.
- **`Containerfile`, `Makefile`, `src/nautilus-server/run.sh`** — the enclave image
  build, changed to carry the verifier and its runtime, pin every input, and
  configure verification's egress and scratch space.

## Changes made upstream

Two fixes found while building this service were contributed back and merged, so
they arrive here as part of the vendored baseline rather than as local patches:

- [nautilus#33](https://github.com/MystenLabs/nautilus/pull/33) — a `#[test_only]`
  constructor for `Enclave<T>`. Without it, a package that gates an entry function
  on `verify_signature` cannot be unit tested at all: `Enclave` has private fields
  and is only produced by `register_enclave`, which requires a live attestation.
- [nautilus#34](https://github.com/MystenLabs/nautilus/pull/34) — documentation for
  running prebuilt glibc binaries in an enclave, which this service requires, since
  the image is musl-based and the Move compiler it runs is not.

A third fix, [nautilus#35](https://github.com/MystenLabs/nautilus/pull/35), ships
`allowed_endpoints.yaml` into the image so `/health_check` reports endpoint status
rather than an empty map. It has since merged upstream, but *after* the commit
vendored here (`048bae1d`), so it is not in this baseline; the enclave-image PR
carries it locally until a re-sync picks it up.

## Re-syncing

Nothing automated. To pick up upstream changes, diff the files above against a
newer upstream commit, apply what is wanted, and update the commit recorded at the
top of this file. The vendored surface is small and mostly stable; the Move
`enclave` package is where an upstream change would matter most, since it defines
the on-chain half of the trust model.
