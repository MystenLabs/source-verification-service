// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! The build inputs of a Move package, and the `source_hash` over them. The
//! enclave prunes a freshly cloned package to exactly these files before hashing
//! and building; the `source-hash` binary hashes the same set over a local
//! checkout, so a consumer can reproduce the hash in an attestation without
//! trusting git. Both work from [`build_input_files`], so the hash and the build
//! see the same files.

use fastcrypto::encoding::{Encoding, Hex};
use fastcrypto::hash::{Blake2b256, HashFunction};
use std::io;
use std::path::Path;

/// Package-root files that are build inputs besides the sources.
const MANIFESTS: &[&str] = &["Move.toml", "Move.lock", "Published.toml"];

/// The files that determine a package's build, as paths relative to
/// `package_dir`, lexicographically sorted: `Move.toml`, `Move.lock`, and
/// `Published.toml` when present, plus every `.move` file under `sources/`
/// (recursively). Nothing else — a `README`, a `.git`, a stray `build/`, or a
/// non-`.move` file in `sources/` is not read by the compiler, so it is not an
/// input and is excluded.
///
/// Errors if `package_dir` has no `Move.toml`: a directory without one is not a
/// package, and treating it as one would hash nothing rather than report the
/// mistake.
pub fn build_input_files(package_dir: &Path) -> io::Result<Vec<String>> {
    if !package_dir.join("Move.toml").is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{package_dir:?} is not a Move package: no Move.toml"),
        ));
    }
    let mut files: Vec<String> = MANIFESTS
        .iter()
        .filter(|n| package_dir.join(n).is_file())
        .map(|n| (*n).to_string())
        .collect();
    let sources = package_dir.join("sources");
    if sources.is_dir() {
        collect_move_files(package_dir, &sources, &mut files)?;
    }
    files.sort();
    Ok(files)
}

/// Lowercase hex of a blake2b256 over a lexicographically-sorted manifest of the
/// package's [build inputs](build_input_files): for each file, its path relative
/// to `package_dir`, a NUL, and `blake2b256(contents)`. Paths and file
/// boundaries are part of the hash, so contents cannot be shuffled between files
/// undetected. Reads only; `package_dir` is never modified. Errors if there is no
/// `Move.toml`.
pub fn source_hash(package_dir: &Path) -> io::Result<String> {
    let mut manifest = Blake2b256::new();
    for rel in build_input_files(package_dir)? {
        let content = std::fs::read(package_dir.join(&rel))?;
        manifest.update(rel.as_bytes());
        manifest.update([0u8]);
        manifest.update(Blake2b256::digest(content).digest);
    }
    Ok(Hex::encode(manifest.finalize().digest))
}

/// Collect `.move` files under `dir` as paths relative to `root`, recursively.
fn collect_move_files(root: &Path, dir: &Path, out: &mut Vec<String>) -> io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            collect_move_files(root, &path, out)?;
        } else if path.extension().is_some_and(|e| e == "move") {
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

    /// A fresh scratch dir holding a minimal package: a manifest and one source.
    fn minimal(name: &str) -> PathBuf {
        let dir = scratch(name);
        write(&dir, "Move.toml", "[package]\nname = \"p\"\n");
        write(&dir, "sources/m.move", "module 0x0::m {}\n");
        dir
    }

    #[test]
    fn excludes_non_inputs() {
        let dir = minimal("extraneous");
        let before = source_hash(&dir).unwrap();

        write(&dir, "README.md", "hello\n");
        write(&dir, ".git/config", "[core]\n");
        write(&dir, "build/p/bytecode.mv", "\x00\x01\x02");
        write(&dir, "tests/m_tests.move", "module 0x0::m_tests {}\n");
        write(&dir, "sources/notes.txt", "not compiled\n"); // non-.move in sources/
        assert_eq!(
            source_hash(&dir).unwrap(),
            before,
            "only .move under sources/ and the manifests count"
        );
    }

    #[test]
    fn tracks_each_build_input() {
        // Each mutation is applied to its own clean package and compared against
        // the untouched baseline, so a hash that ignored one input would still be
        // caught (a cumulative test would not isolate which input mattered).
        let base = source_hash(&minimal("base")).unwrap();

        let edit = minimal("edit");
        write(&edit, "sources/m.move", "module 0x0::m { fun f() {} }\n");
        assert_ne!(source_hash(&edit).unwrap(), base, "editing a source");

        let add_src = minimal("add-source");
        write(&add_src, "sources/n.move", "module 0x0::n {}\n");
        assert_ne!(source_hash(&add_src).unwrap(), base, "adding a source");

        let lock = minimal("lock");
        write(&lock, "Move.lock", "# lock\n");
        assert_ne!(source_hash(&lock).unwrap(), base, "adding Move.lock");

        let published = minimal("published");
        write(&published, "Published.toml", "[published.testnet]\n");
        assert_ne!(
            source_hash(&published).unwrap(),
            base,
            "adding Published.toml"
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
    fn independent_of_location() {
        // The same contents at two different paths must hash identically, so the
        // hash depends on the package's contents and not on where it is checked out.
        let a = minimal("loc-a");
        let b = minimal("loc-b");
        assert_eq!(source_hash(&a).unwrap(), source_hash(&b).unwrap());
    }
}
