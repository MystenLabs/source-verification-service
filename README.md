# source-verification-service

Verifiable Move source verification in an AWS Nitro enclave, recorded on Sui.

An enclave rebuilds a published Move package from its source and compares the
result against the bytecode on chain. When they match it signs a statement
saying so, which anyone can record as an on-chain attestation.

The point is that the statement is worth something without trusting whoever ran
it: the enclave's measurements say what code produced the signature, and the
whole check can be reproduced by anyone who doubts it.

This branch is a placeholder. The system arrives as a reviewable series:

| PR | Contents |
| --- | --- |
| 1 | Design and trust model — what is claimed, and what deliberately is not |
| 2 | The vendored Nautilus subset this builds on |
| 3 | The enclave image, and how to reproduce its measurements |
| 4 | The enclave application |
| 5 | The on-chain contract and the client |

Read PR 1 first; the rest are best judged against the contract it states.
