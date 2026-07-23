# source-verification-service

Verifiable Move source verification in an AWS Nitro enclave, recorded on Sui.

A Move package published on Sui exists on chain as bytecode. Its source lives in
a git repository, and nothing connects the two — a project can point at any
repository and claim it is what runs. This service closes that gap without asking
anyone to trust it.

An AWS Nitro enclave clones the source, rebuilds it with the compiler the package
was published with, and compares the result against the on-chain bytecode and
linkage. When they match it signs a statement to that effect, which anyone can
record on chain as an `Attestation<SourceVerification>`.

The statement is worth something without trusting whoever produced it. The
enclave's measurements say what code created the signature, the payload records
which compiler performed the rebuild, and the whole check can be reproduced by
anyone who doubts it. What it establishes is narrow and worth stating plainly: it
is an **identity** check — the code you can read is the code that runs — not a
security review. A verified package can still be malicious.

## Reading order

- **[DESIGN.md](DESIGN.md)** — what an attestation claims, what it deliberately
  does not, and everything that has to hold for it to be sound. Start here; the
  rest is best judged against the contract it states.
- **[VENDORED.md](VENDORED.md)** — this builds on
  [Nautilus](https://github.com/MystenLabs/nautilus), vendored rather than forked.
  This records which commit, and how to verify the import.
