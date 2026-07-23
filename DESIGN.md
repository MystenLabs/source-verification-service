# Design and trust model

## What this service does

A Move package published on Sui exists on chain as bytecode. Its source lives in
a git repository, and nothing connects the two: a project can point at any
repository and claim it is what runs.

This service closes that gap without asking anyone to trust it. An AWS Nitro
enclave fetches the source, rebuilds it with the compiler the package was
published with, and compares the result against the on-chain bytecode and
linkage. If they match it signs a statement to that effect. Anyone can record
that statement on chain as an `Attestation<SourceVerification>`.

The current implementation requires the source — the root package and its
dependencies — to be hosted on GitHub; see [Known gaps](#known-gaps).

## What an attestation claims

Precisely this:

> An enclave whose measurements are PCR0/PCR1 fetched the source at `git_url`,
> `subdir`, commit `git_sha`, whose contents hash to `source_hash`; rebuilt it
> using the compiler at version `toolchain_version` with sha256
> `toolchain_digest`; and found the result identical to the bytecode and linkage
> of the package at `pkg_id`.

Note what is *not* claimed.

**Not that the source is safe, correct, or audited.** This is an identity check,
not a security review. A verified package can be malicious. It says the code you
can read is the code that runs.

**Not that `git_url` still serves that source.** The git fields are provenance
for finding the source, not integrity. `source_hash` is the authoritative
identifier, and it is a blake2b256 over the package directory — git's SHA-1 is
not collision resistant and must not be relied on. See
[Why not the git hash](#why-not-the-git-hash).

**Not that the compiler was honest.** The compiler is downloaded at run time and
is therefore outside the enclave's measurements. See
[The unmeasured compiler](#the-unmeasured-compiler).

## Why it is worth anything

An attestation is best understood as a **reverifiable cache**. Nothing in it is
a claim only this service can make: anyone can run `sui client verify-source`
themselves and reach the same answer. What the service provides is that the
answer is already computed, signed, and recorded — and that producing a *false*
one requires compromising a specific, enumerable set of things.

That framing matters because it bounds the damage. A forged attestation is
detectable by anyone who re-runs the check, so an attacker gains only the window
before someone looks. The exception is **on-chain consumers**, which cannot
re-run anything at call time; they are the parties for whom the trust roots below
genuinely bite, and they are the reason the payload records the compiler rather
than assuming it.

## Trust roots

An attestation is sound only if all of the following hold.

**AWS.** The Nitro attestation PKI. AWS signs the document that says which
measurements a running enclave has. AWS could sign a false one.

**The Sui framework.** `sui::nitro_attestation`, the native that verifies those
documents on chain, and the framework it lives in.

**The `attestations` package.** Mysten's shared registry, and whoever holds its
upgrade capability.

**A Sui fullnode.** The enclave fetches the on-chain package from a hardcoded
endpoint (mainnet or testnet, by `build_env`) and trusts it to return the real
bytecode. This could be relaxed in the future by verifying against a
committee-signed checkpoint. It adds no new party — the endpoints are Mysten's —
and the parent instance is *not* trusted here: TLS terminates inside the enclave,
so the host can deny service but not tamper.

**Three capabilities held by this project**, each of which can independently
forge an attestation:

1. the `source_verification` package's upgrade capability;
2. the vendored `enclave` package's upgrade capability — a full forge vector, since
   an upgraded `enclave` could mint an `Enclave<SourceVerifier>` around any key;
3. the `EnclaveConfig` maintainer capability, which can `update_pcrs` to point at
   an image of its choosing.

These are kept rather than burned, because upgradability is needed — a future
Move bytecode format change would otherwise strand the service. Freezing one
while another remains is theatre. They should be held jointly in a multisig,
ideally with a timelock on `update_pcrs` and on upgrades.

**Not a trust root: whoever runs the enclave.** `register_enclave` is
permissionless. Anyone who runs the attested image can register their own
`Enclave<SourceVerifier>` against the shared config and serve attestations, and
`attest_source` accepts any registered enclave *at the current config version*
(see below). Multi-provider is inherent to the design rather than a feature added
to it.

### Rotation is enforced

When the image changes, the `EnclaveConfig` maintainer calls `update_pcrs`, which
bumps a version counter. `attest_source` records a signature only if the enclave
registered against the *current* version. So rotating the PCRs immediately stops
enclaves running the old image from producing attestations — the operator does
not have to cooperate, and there is no window in which a rotated-out image is
still accepted.

Without this, revocation would depend on someone destroying each stale `Enclave`
object, which makes it a cleanup task rather than a control. The check is what
turns `update_pcrs` into an actual kill switch: raise the config version and every
enclave below it is rejected on its next call.

Reading the two version fields requires accessors (`Enclave::config_version`,
`EnclaveConfig::version`) that the upstream `enclave` package does not expose;
this repository adds them to its vendored copy.

## The unmeasured compiler

`verify-source` rebuilds a package with the toolchain that published it —
downloaded at run time, because the service must handle packages published by
any historical or future release. The enclave's PCRs measure the *image*; they
cannot
measure something the image fetches later.

So the attestation would otherwise assert a rebuild without saying what performed
it, and a substituted release would be indistinguishable from an authentic one.

The payload therefore records `toolchain_version` and `toolchain_digest`, the
sha256 of the compiler binary **as executed**. A consumer can check that digest
against the official release for that version and decide whether to believe the
rebuild. This does not eliminate the trust; it makes it visible and falsifiable
after the fact, which is the most that can be done without pinning an allowlist
of compiler digests into the image and re-releasing for every new toolchain.

The digest is of the binary rather than of the release archive because the
compiler may come from a cache or be the verifier's own executable; the binary is
the thing that actually ran in every case.

### The verifier is the same kind of artifact

The program that *drives* the comparison — reading the publication metadata,
fetching the toolchain, invoking it, fetching the on-chain package, comparing the
results — is the `sui` binary too, baked into the image rather than downloaded.

It is worth being explicit that this is not a stronger trust assumption than the
one above, because it looks like one. A malicious compiler produces bytecode that
matches a malicious source; a malicious verifier simply reports a match that did
not happen. Both are complete breaks of the same property. Since the compiler is
already an official release fetched at run time, taking the verifier from the same
channel adds no new class of trust.

What differs is *how each is pinned*. The compiler is not in the image, so it is
recorded in the payload where a consumer can check it. The verifier is in the
image, so it is covered by PCR0/PCR1 — a stronger binding, provided the image can
be reproduced.

That condition is why the verifier should be an official release rather than
something built for the purpose. A published release artifact is already
content-addressed and already fetchable, so reproducing the image means
downloading it and checking its digest — introducing no artifact of this
project's own that anyone must obtain by a different route, or trust by a
different argument, than the toolchains they are downloading anyway.

Until the verification code appears in a release, the image is built from a pinned
revision **and** a pinned binary digest, because `cargo build --release` is not
guaranteed to be byte reproducible: the revision records provenance, the digest is
what pins the measurements. Both are in the `Makefile`, and a mismatch fails the
build rather than silently producing an image whose PCRs do not match the
published ones.

## Why not the git hash

The obvious identifier for "which source" is the git commit. It is not used as
the authoritative one for two reasons.

Git commits are SHA-1. Collision resistance is broken, and while git's
`sha1dc` detection raises the cost considerably, an identifier underpinning a
supply-chain claim should not depend on it.

Requiring SHA-256 repositories was considered and rejected. GitHub does not
support them, so every project would need a mirror — and a mirror **relocates**
the trust rather than removing it: to believe the mirror is the real project you
compare it against the SHA-1 original. A commit hash also covers the whole
repository, so an unrelated change elsewhere in a monorepo would change the
identifier of an untouched package.

`source_hash` is a blake2b256 over a sorted manifest of the package's source: for
each file, its path **relative to the package directory**, a NUL, and the hash of
its contents. The set of files hashed is what determines the build — everything
under `sources/`, plus `Move.toml`, `Move.lock`, and `Published.toml` — and
nothing else, so an unrelated file (a README, a test fixture, a stray `build/`
directory) does not change the identifier. Paths and file boundaries are part of
the hash, so contents cannot be shuffled between files undetected. It answers
exactly the question a consumer has — *is this the same package* — and is
reproducible from the source alone.

> **Implementation note.** The current code hashes *every* file in the package
> directory rather than this defined set. That is a bug — for a root-level
> package it would even fold in `.git` — and this section describes the intended
> behavior, which the code should be changed to match.

The residual risk is that a consumer follows `git_url` to read source that a
SHA-1 collision has substituted. The attestation itself is unaffected; only
discovery is misled. The mitigation is to make checking `source_hash` easy enough
that nobody skips it — a `verify-source` subcommand or a short script that prints
the hash for a local checkout, so comparing is one command. (Not yet built.)

## Design decisions

**The enclave signs; the client submits.** The enclave never holds a funded key
and never sends a transaction. Everything valuable is in the signature, and
submission is a commodity operation anyone can perform. A key held by the host
would sit outside the attestation entirely, and a service that pays its own gas
can be drained by anyone who asks it to work.

**The request carries no compiler override.** `verify-source` accepts
`--toolchain-version` for packages whose recorded toolchain cannot be built, but
this service does not expose it. `Published.toml` lives inside the package
directory and is therefore covered by `source_hash`, so recording the toolchain
there keeps every input to the result inside the hash. A request-time override
would be the one input a consumer could not see. Packages with an unusable
recorded toolchain are fixed by correcting `Published.toml`, which fixes them for
everyone permanently.

**`attest_source` takes fields, not a struct.** A programmable transaction can
supply only primitives and a few special types as pure arguments, so a function
taking `SourceVerification` by value could not be called at all. Rebuilding the
struct inside is also what gives the signature check meaning: it verifies against
exactly what the caller supplied.

**Verifications are serialized.** Each one holds a checkout, a build tree, and a
~200 MB compiler in a filesystem that is RAM. Concurrency multiplies the scarcest
resource, and exhausting it kills the enclave rather than the request — losing the
ephemeral key and forcing a re-registration.

**Scratch space is a sized tmpfs, and each request gets its own `MOVE_HOME`.**
The enclave root is the unpacked initramfs: RAM, and unbounded. A sized tmpfs
turns exhaustion into `ENOSPC` against one request instead of an OOM that takes
the enclave down. Per-request `MOVE_HOME` matters because dependency caches
accumulate per framework revision — packages published by older releases clone
whole repositories, 300–800 MB each, and there are over a hundred verifiable
releases.

## Known gaps

**No freshness check.** A signed response is submittable indefinitely, and by
anyone who sees it. Duplicate attestations for one package are possible. Since
submission costs gas and confers no advantage, this is accepted.

Note that this is *within* a config version. Rotating the PCRs does revoke: an
enclave signature is only recorded if the enclave registered against the current
`EnclaveConfig` version (see [Rotation is enforced](#rotation-is-enforced)), so
an old response stops being submittable once `update_pcrs` runs.

**Egress is an allowlist, so only some hosts are verifiable.** The enclave has no
DNS — only fixed `/etc/hosts` entries — which blocks SSRF neatly but limits what
can be verified. The allowlist is **GitHub only** to start, so the root package
*and every dependency it resolves* must be hosted on GitHub; a package with a
dependency fetched from anywhere else cannot be verified until that host is added.
Widening this is a matter of extending the allowlist and the traffic forwarder,
not a design change.

**PCR2 does not bind anything.** It has been identical across every image built
here regardless of contents. PCR0 and PCR1 are what tie an attestation to an
image; pinning PCR2 costs nothing but proves nothing.

**Availability is unprotected.** Verifications are serialized and take minutes, so
an unauthenticated endpoint can be monopolized at no cost to the caller. Caching
identical requests and rate limiting at the host are the obvious mitigations;
neither is implemented.
