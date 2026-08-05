// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Prints the `source_hash` of a local Move package directory, so it can be
//! compared against the `source_hash` in a `SourceVerification` attestation
//! without trusting the git commit. This is the same computation the enclave
//! performs, so a match means the on-chain attestation is about this source.
//!
//! Usage: `source-hash <package-dir>`

use nautilus_server::source_hash::source_hash;
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let (Some(dir), None) = (args.next(), args.next()) else {
        eprintln!("usage: source-hash <package-dir>");
        return ExitCode::FAILURE;
    };
    match source_hash(&PathBuf::from(dir)) {
        Ok(hash) => {
            println!("{hash}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("source-hash: {e}");
            ExitCode::FAILURE
        }
    }
}
