/// Source verification — standalone Nautilus + attestations.
///
/// A Nitro enclave running the verify-source workload signs a
/// `SourceVerification` over a Move package it checked against its on-chain
/// bytecode. This module verifies that signature against a registered
/// `Enclave<SourceVerifier>` and records the result as an
/// `Attestation<SourceVerification>` about the on-chain package. Registration is
/// permissionless (`enclave::register_enclave`), so anyone running the attested
/// PCRs can provide the service; `attest_source` accepts any such enclave.
module source_verification::source_verification;

use std::internal;
use std::string::String;
use sui::display_registry::DisplayRegistry;
use enclave::enclave::{Self, Enclave, EnclaveConfig};
use attestations::attestations::{Registry, attest};

#[test_only]
use sui::test_scenario;

#[error(code = 0)]
const EBadSignature: vector<u8> =
    b"enclave signature does not verify against the registered enclave";

#[error(code = 1)]
const EStaleEnclave: vector<u8> =
    b"enclave registered against PCRs that have since been rotated";

/// Intent scope the enclave stamps when signing a `SourceVerification`. Must
/// match `IntentScope::SourceVerification` in the enclave server.
const VERIFY_SCOPE: u8 = 0;

/// Marker `T` for this skill's `EnclaveConfig<T>` / `Enclave<T>`. A plain `drop`
/// witness (not a one-time witness): only this module can name it, so only this
/// module can create the enclave config/cap and verify signatures under it.
public struct SourceVerifier has drop {}

/// The attestation payload: package `pkg_id` was built from the source at
/// `git_url`/`subdir` (resolved commit `git_sha`), whose contents hash to
/// `source_hash`. `source_hash` (blake2b256 of the package dir) is the
/// authoritative identifier; the git fields are informational provenance only —
/// git's SHA-1 is not collision-resistant. Field order + types are pinned to the
/// enclave server's Rust `SourceVerification` by a cross-language BCS byte-test.
///
/// `toolchain_version` and `toolchain_digest` name the compiler that performed
/// the rebuild. The enclave downloads that compiler at run time, so it is not
/// covered by the PCRs in `EnclaveConfig`: the PCRs attest to the image, and
/// these two fields attest to what the image then fetched and ran.
/// `toolchain_digest` is sha256 of that binary, so a consumer can check it
/// against the official release for `toolchain_version` and decide whether to
/// believe the rebuild.
///
/// Both digests are lowercase hex strings, not byte vectors: they exist to be
/// compared by whoever reads the attestation, and a `vector<u8>` renders in an
/// explorer as a list of decimal numbers that cannot be compared with anything.
#[allow(unused_field)]
public struct SourceVerification has copy, store, drop {
    pkg_id: ID,
    source_hash: String,
    git_url: String,
    subdir: String,
    git_sha: String,
    toolchain_version: String,
    toolchain_digest: String,
}

/// Publish-time: mint the enclave `Cap<SourceVerifier>` and hand it to the
/// publisher. That cap is the one thing only this module can produce — it needs
/// the `SourceVerifier` witness — so `init` mints it and nothing else.
///
/// Everything downstream is deployment data, set by the cap holder in a
/// transaction rather than compiled in here: the shared
/// `EnclaveConfig<SourceVerifier>` is created with the image's PCRs via
/// `enclave::create_enclave_config`, and its PCRs are rotated with
/// `enclave::update_pcrs`. So a new enclave image needs no change to this
/// package. The concrete PCRs and the commands are in `DEPLOYMENT.md`. Providers
/// then permissionlessly `register_enclave` their own `Enclave<SourceVerifier>`
/// against that config.
fun init(ctx: &mut TxContext) {
    transfer::public_transfer(enclave::new_cap(SourceVerifier {}, ctx), ctx.sender());
}

/// Verify an enclave-signed `SourceVerification` and record it as an
/// `Attestation<SourceVerification>` about `pkg_id`. Accepts any
/// `Enclave<SourceVerifier>` registered against `config` (permissionless
/// multi-provider). `registry` is the attestations `Registry` id. Returns the
/// new attestation's ID.
///
/// Aborts `EStaleEnclave` unless the enclave registered against the *current*
/// config version. Without that check, rotating the PCRs would not revoke
/// anything: an `Enclave` object registered against the old ones keeps a working
/// key, and its signatures stay acceptable for as long as the object exists.
/// Revocation would then depend on someone calling `destroy_old_enclave`, which
/// makes it a cleanup task rather than a control. With the check, `update_pcrs`
/// takes effect immediately.
///
/// Taking `config`/`enclave` as arguments is safe: an
/// `EnclaveConfig<SourceVerifier>` can only be made by `create_enclave_config`,
/// which needs a `Cap<SourceVerifier>`, which needs a `SourceVerifier` witness this
/// module mints only in `init`. A caller cannot forge a config with PCRs of their
/// choosing — a `Cap` holder could, but that is one of the trust roots named in
/// DESIGN.
///
/// The payload arrives as fields rather than as a `SourceVerification` because a
/// programmable transaction can supply only primitives, vectors and a handful of
/// special types as pure arguments; an arbitrary Move struct is not among them,
/// so taking the struct by value would make this uncallable. Rebuilding it here
/// is also what gives the signature check its meaning — the signature is checked
/// against the fields the caller actually supplied.
public fun attest_source(
    registry: ID,
    enclave: &Enclave<SourceVerifier>,
    config: &EnclaveConfig<SourceVerifier>,
    pkg_id: ID,
    source_hash: String,
    git_url: String,
    subdir: String,
    git_sha: String,
    toolchain_version: String,
    toolchain_digest: String,
    timestamp_ms: u64,
    signature: vector<u8>,
    ctx: &mut TxContext,
): ID {
    let payload = SourceVerification {
        pkg_id,
        source_hash,
        git_url,
        subdir,
        git_sha,
        toolchain_version,
        toolchain_digest,
    };
    assert!(enclave.config_version() == config.version(), EStaleEnclave);
    assert!(
        enclave.verify_signature(VERIFY_SCOPE, timestamp_ms, payload, &signature),
        EBadSignature,
    );
    attest(registry, internal::permit<SourceVerification>(), pkg_id, payload, ctx)
}

/// One-shot setup of the `Display<Attestation<SourceVerification>>`. Call once
/// shortly after publish; aborts on a second call.
///
/// The Display is **append-only**: `attestations::add_display_field` refuses a
/// field that is already set, and nothing exposes overwrite, unset or clear. So
/// these strings are permanent once this runs, and getting them wrong cannot be
/// corrected -- only added to. `image_url` is deliberately absent: it needs a
/// stable public URL, and it can be appended later without disturbing these.
///
/// `link` is a fixed URL to this service, not the verified repository. By the
/// attestations conventions it names the artifact backing the attestation -- an
/// audit attestation links its report -- and this service produces no report, so
/// what a reader needs is what the claim means and how to reproduce it. The
/// verified repository is already in the description, as data.
///
/// It is also the only safe choice: those conventions tell consumers to constrain
/// `link` to the attester's known domains, and interpolating the requester-supplied
/// `git_url` would make it vary per attestation and point at hosts this service
/// does not control.
///
/// Beyond `name`/`description`/`link`, each payload field is also its own Display
/// field (`git_url`, `git_sha`, …), so a frontend can read the metadata structured
/// rather than parsing the description. The schema is written out here — in the
/// source — deliberately, rather than passed in at call time, because it *is* the
/// contract's public shape and belongs where it can be reviewed.
entry fun register_source_display(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    let mut fields = vector[
        b"name".to_string(),
        b"description".to_string(),
        b"link".to_string(),
    ];
    let mut values = vector[
        b"Verified source".to_string(),
        b"The source at {data.git_url} ({data.git_sha}), subdirectory {data.subdir}, compiles to the bytecode published at {data.pkg_id}. Rebuilt with sui {data.toolchain_version}. Source hash {data.source_hash}.".to_string(),
        b"https://github.com/MystenLabs/source-verification-service".to_string(),
    ];
    // Each payload field, rendered as itself.
    fields.push_back(b"git_url".to_string());
    values.push_back(b"{data.git_url}".to_string());
    fields.push_back(b"git_sha".to_string());
    values.push_back(b"{data.git_sha}".to_string());
    fields.push_back(b"subdir".to_string());
    values.push_back(b"{data.subdir}".to_string());
    fields.push_back(b"pkg_id".to_string());
    values.push_back(b"{data.pkg_id}".to_string());
    fields.push_back(b"toolchain_version".to_string());
    values.push_back(b"{data.toolchain_version}".to_string());
    fields.push_back(b"toolchain_digest".to_string());
    values.push_back(b"{data.toolchain_digest}".to_string());
    fields.push_back(b"source_hash".to_string());
    values.push_back(b"{data.source_hash}".to_string());
    registry.register_display(
        display_registry,
        internal::permit<SourceVerification>(),
        fields,
        values,
        ctx,
    );
}

#[test]
/// Pins the `SourceVerification` signing-byte layout against the enclave
/// server's Rust `signing_bytes` test — the enclave↔chain contract.
fun signing_bytes_match_rust() {
    let payload = SourceVerification {
        pkg_id: object::id_from_address(@0x2a),
        source_hash: b"abc".to_string(),
        git_url: b"https://example.com/repo.git".to_string(),
        subdir: b"pkg".to_string(),
        git_sha: b"1234567890abcdef1234567890abcdef12345678".to_string(),
        toolchain_version: b"1.71.1".to_string(),
        toolchain_digest: b"xyz".to_string(),
    };
    let msg = enclave::create_intent_message(VERIFY_SCOPE, 1_700_000_000_000, payload);
    let expected =
        x"000068e5cf8b010000000000000000000000000000000000000000000000000000000000000000002a036162631c68747470733a2f2f6578616d706c652e636f6d2f7265706f2e67697403706b67283132333435363738393061626364656631323334353637383930616263646566313233343536373806312e37312e310378797a";
    assert!(sui::bcs::to_bytes(&msg) == expected);
}

#[test_only]
/// A registry, a config created through the real path, and an enclave holding the
/// fixed test key. Returns them for the caller to consume.
fun setup(scenario: &mut test_scenario::Scenario, alice: address): (Registry, EnclaveConfig<SourceVerifier>, Enclave<SourceVerifier>) {
    attestations::attestations::init_for_testing(scenario.ctx());
    let cap = enclave::new_cap(SourceVerifier {}, scenario.ctx());
    enclave::create_enclave_config(&cap, b"test".to_string(), x"00", x"00", x"00", scenario.ctx());
    let enclave = enclave::new_enclave_for_testing<SourceVerifier>(
        x"d04a166e8dcd71127be0012f3e882c9b8c355af7d43dd98f8200b69eb17e312f",
        scenario.ctx(),
    );
    transfer::public_transfer(cap, alice);
    scenario.next_tx(alice);
    let registry: Registry = scenario.take_shared();
    let config: EnclaveConfig<SourceVerifier> = scenario.take_shared();
    (registry, config, enclave)
}

#[test_only]
/// Attest the fixed test payload with the valid test signature (the one the
/// enclave app's `signing_bytes` test emits). Aborts if the config/enclave check
/// or the signature check fails.
fun attest_fixture(
    registry: &Registry,
    enclave: &Enclave<SourceVerifier>,
    config: &EnclaveConfig<SourceVerifier>,
    ctx: &mut TxContext,
): ID {
    attest_source(
        object::id(registry),
        enclave,
        config,
        object::id_from_address(@0x2a),
        b"abc".to_string(),
        b"https://example.com/repo.git".to_string(),
        b"pkg".to_string(),
        b"1234567890abcdef1234567890abcdef12345678".to_string(),
        b"1.71.1".to_string(),
        b"xyz".to_string(),
        1_700_000_000_000,
        x"2bf813528e1ac24bc5d5da7b7529cc15b706c2a9e1cb6606752049dc7ffabc626454ab5d5586f7af1cf5f20539184fe997aa86f1954ae0158adb301966fdc905",
        ctx,
    )
}

#[test]
#[expected_failure(abort_code = EStaleEnclave)]
/// Rotating the PCRs revokes an enclave registered against the old ones, even
/// though its key still signs correctly. The *same* valid signature is accepted
/// before `update_pcrs` and rejected after, so the failure below is the rotation,
/// not a bad signature.
fun attest_source_rejects_stale_enclave() {
    let alice = @0xA11CE;
    let mut scenario = test_scenario::begin(alice);
    let (registry, mut config, enclave) = setup(&mut scenario, alice);

    // Accepted while the enclave's config version is current.
    let _ = attest_fixture(&registry, &enclave, &config, scenario.ctx());

    scenario.next_tx(alice);
    let cap: enclave::Cap<SourceVerifier> = scenario.take_from_sender();
    enclave::update_pcrs(&mut config, &cap, x"01", x"01", x"01");

    // The same response, rejected now that the config has rotated out from under it.
    let _ = attest_fixture(&registry, &enclave, &config, scenario.ctx());

    scenario.return_to_sender(cap);
    test_scenario::return_shared(registry);
    test_scenario::return_shared(config);
    enclave::destroy(enclave);
    scenario.end();
}

#[test]
/// `attest_source` accepts a payload correctly signed by a registered enclave
/// and mints the attestation. The `Enclave<SourceVerifier>` is fabricated with
/// the fixed test pubkey, and the signature is the matching one emitted by the
/// enclave app's `signing_bytes` test over the same payload.
fun attest_source_accepts_valid_signature() {
    let alice = @0xA11CE;
    let mut scenario = test_scenario::begin(alice);
    let (registry, config, enclave) = setup(&mut scenario, alice);
    let _ = attest_fixture(&registry, &enclave, &config, scenario.ctx());

    test_scenario::return_shared(registry);
    test_scenario::return_shared(config);
    enclave::destroy(enclave);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = EBadSignature)]
/// A signature that doesn't verify against the enclave's key is rejected.
fun attest_source_rejects_bad_signature() {
    let alice = @0xA11CE;
    let mut scenario = test_scenario::begin(alice);
    let (registry, config, enclave) = setup(&mut scenario, alice);
    let _ = attest_source(
        object::id(&registry),
        &enclave,
        &config,
        object::id_from_address(@0x2a),
        b"abc".to_string(),
        b"https://example.com/repo.git".to_string(),
        b"pkg".to_string(),
        b"1234567890abcdef1234567890abcdef12345678".to_string(),
        b"1.71.1".to_string(),
        b"xyz".to_string(),
        1_700_000_000_000,
        x"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        scenario.ctx(),
    );

    test_scenario::return_shared(registry);
    test_scenario::return_shared(config);
    enclave::destroy(enclave);
    scenario.end();
}
