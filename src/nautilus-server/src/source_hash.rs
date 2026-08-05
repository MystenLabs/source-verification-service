// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! The `source_hash` identifier of a Move package. The enclave computes it over
//! a freshly cloned package before verifying it; the `source-hash` binary
//! computes the same value over a local checkout, so a consumer can reproduce
//! the hash in an attestation without trusting git.

use fastcrypto::encoding::{Encoding, Hex};
use fastcrypto::hash::{Blake2b256, HashFunction};
use std::io;
use std::path::Path;

/// The build inputs at the top level of a package directory. `sources` is a
/// directory hashed recursively; the rest are files. Everything else in the
/// directory is excluded.
const INPUTS: &[&str] = &["sources", "Move.toml", "Move.lock", "Published.toml"];

/// Lowercase hex of a blake2b256 over a lexicographically-sorted manifest of a
/// package's build inputs: for each file, its path relative to `package_dir`, a
/// NUL, and `blake2b256(contents)`.
///
/// The hashed set is everything under `sources/` plus `Move.toml`, `Move.lock`,
/// and `Published.toml` — the files that determine the build — and nothing else,
/// so an unrelated file (a `README`, a `.git`, a stray `build/`) does not change
/// the result. Paths and file boundaries are part of the hash, so contents
/// cannot be shuffled between files undetected. Reads only; `package_dir` is
/// never modified.
///
/// Errors if `package_dir` has no `Move.toml`: a directory without one is not a
/// package, and hashing it would return a hash of nothing rather than reporting
/// the mistake.
pub fn source_hash(package_dir: &Path) -> io::Result<String> {
    if !package_dir.join("Move.toml").is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{package_dir:?} is not a Move package: no Move.toml"),
        ));
    }
    let mut files = Vec::new();
    for name in INPUTS {
        let path = package_dir.join(name);
        if path.is_dir() {
            collect_files(package_dir, &path, &mut files)?;
        } else if path.is_file() {
            files.push((*name).to_string());
        }
    }
    files.sort();
    let mut manifest = Blake2b256::new();
    for rel in files {
        let content = std::fs::read(package_dir.join(&rel))?;
        manifest.update(rel.as_bytes());
        manifest.update([0u8]);
        manifest.update(Blake2b256::digest(content).digest);
    }
    Ok(Hex::encode(manifest.finalize().digest))
}

/// Collect files under `dir` as paths relative to `root`, recursively.
fn collect_files(root: &Path, dir: &Path, out: &mut Vec<String>) -> io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            collect_files(root, &path, out)?;
        } else {
            out.push(
                path.strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    /// A fresh, empty scratch directory unique to `name`, removed if it lingered
    /// from a previous run.
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("svc-source-hash-{name}"));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    /// Write `contents` to `dir/rel`, creating parent directories.
    fn write(dir: &Path, rel: &str, contents: &str) {
        let path = dir.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    /// A minimal package: a manifest and one source file.
    fn minimal(dir: &Path) {
        write(dir, "Move.toml", "[package]\nname = \"p\"\n");
        write(dir, "sources/m.move", "module 0x0::m {}\n");
    }

    #[test]
    fn ignores_files_outside_the_build_inputs() {
        let dir = scratch("extraneous");
        minimal(&dir);
        let before = source_hash(&dir).unwrap();

        write(&dir, "README.md", "hello\n");
        write(&dir, ".git/config", "[core]\n");
        write(&dir, "build/p/bytecode.mv", "\x00\x01\x02");
        write(&dir, "tests/m_tests.move", "module 0x0::m_tests {}\n");
        assert_eq!(source_hash(&dir).unwrap(), before);
    }

    #[test]
    fn tracks_the_build_inputs() {
        let dir = scratch("inputs");
        minimal(&dir);
        let base = source_hash(&dir).unwrap();

        write(&dir, "sources/m.move", "module 0x0::m { fun f() {} }\n");
        let changed_source = source_hash(&dir).unwrap();
        assert_ne!(changed_source, base, "a source edit must change the hash");

        write(&dir, "sources/m.move", "module 0x0::m {}\n");
        write(&dir, "Move.lock", "# lock\n");
        assert_ne!(
            source_hash(&dir).unwrap(),
            base,
            "adding a manifest must change the hash"
        );
    }

    #[test]
    fn errs_without_a_manifest() {
        let dir = scratch("nomanifest");
        write(&dir, "sources/m.move", "module 0x0::m {}\n");
        assert!(
            source_hash(&dir).is_err(),
            "no Move.toml must be an error, not the empty hash"
        );
    }

    #[test]
    fn is_stable_across_runs() {
        let dir = scratch("stable");
        minimal(&dir);
        assert_eq!(source_hash(&dir).unwrap(), source_hash(&dir).unwrap());
    }
}
