// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This module defines the VersionWitness type used to track the version of the protocol.
/// This type is used as a regular witness, but for an entire package instead of a single module.

module account_protocol::version_witness;

use std::ascii::String as AsciiString;
use std::type_name;
use sui::address;
use sui::hex;

// === Imports ===

// === Errors ===
const EInvalidVersionWitnessType: u64 = 0;

// === Constants ===
const ASCII_LT: u8 = 60; // '<'
const ASCII_V_UPPER: u8 = 86; // 'V'
const ASCII_ZERO: u8 = 48; // '0'
const ASCII_NINE: u8 = 57; // '9'

const MODULE_VERSION: vector<u8> = b"version";
const MODULE_VERSION_WITNESS: vector<u8> = b"version_witness";
const VERSION_MODULE_SUFFIX: vector<u8> = b"_version";

// === Structs ===

/// Witness to check the version of a package.
public struct VersionWitness has copy, drop {
    // package id where the witness has been created
    package_addr: address,
}

/// Creates a new VersionWitness for the package where the witness is instantiated.
///
/// SECURITY: The provided witness type must be a version witness type
/// (module `version` / `*_version` and struct name `V<digits>`).
/// This prevents forging package proofs from arbitrary public marker constructors.
public fun new<PW: drop>(_package_witness: PW): VersionWitness {
    let package_type = type_name::with_original_ids<PW>();
    assert!(is_valid_version_witness_type(&package_type), EInvalidVersionWitnessType);
    let package_addr = address::from_bytes(hex::decode(package_type.address_string().into_bytes()));

    VersionWitness { package_addr }
}

// === Public Functions ===

/// Returns the address of the package where the witness has been created.
public fun package_addr(witness: &VersionWitness): address {
    witness.package_addr
}

fun is_valid_version_witness_type(package_type: &type_name::TypeName): bool {
    if (type_name::is_primitive(package_type)) {
        return false
    };

    let module_name = type_name::module_string(package_type);
    if (!is_valid_version_module(&module_name)) {
        return false
    };

    let struct_name = struct_name_bytes(package_type);
    is_valid_version_struct_name(&struct_name)
}

fun is_valid_version_module(module_name: &AsciiString): bool {
    let module_bytes = module_name.as_bytes();
    if (module_bytes == &MODULE_VERSION || module_bytes == &MODULE_VERSION_WITNESS) {
        return true
    };

    let module_len = module_bytes.length();
    let suffix_len = VERSION_MODULE_SUFFIX.length();
    if (module_len <= suffix_len) {
        return false
    };

    let start = module_len - suffix_len;
    let mut i = 0;
    while (i < suffix_len) {
        if (module_bytes[start + i] != VERSION_MODULE_SUFFIX[i]) {
            return false
        };
        i = i + 1;
    };
    true
}

fun is_valid_version_struct_name(struct_name: &vector<u8>): bool {
    let len = struct_name.length();
    if (len < 2) {
        return false
    };
    if (struct_name[0] != ASCII_V_UPPER) {
        return false
    };

    let mut i = 1;
    while (i < len) {
        let c = struct_name[i];
        if (c < ASCII_ZERO || c > ASCII_NINE) {
            return false
        };
        i = i + 1;
    };
    true
}

fun struct_name_bytes(package_type: &type_name::TypeName): vector<u8> {
    let full_type_bytes = type_name::as_string(package_type).as_bytes();
    let address_len = type_name::address_string(package_type).as_bytes().length();
    let module_len = type_name::module_string(package_type).as_bytes().length();
    let start = address_len + 2 + module_len + 2; // <addr>::<module>::

    if (start >= full_type_bytes.length()) {
        return vector[]
    };

    let mut struct_name = vector[];
    let mut i = start;
    while (i < full_type_bytes.length()) {
        let c = full_type_bytes[i];
        if (c == ASCII_LT) {
            break
        };
        struct_name.push_back(c);
        i = i + 1;
    };
    struct_name
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

// === Test Helpers ===

#[test_only]
public fun new_for_testing(package_addr: address): VersionWitness {
    VersionWitness { package_addr }
}

// === Unit Tests ===

#[test_only]
public struct V1() has drop;

#[test_only]
public struct TestPackageWitness() has drop;

#[test]
fun test_new_version_witness() {
    let witness = new(V1());
    // Should not abort - just testing creation and access
    assert!(package_addr(&witness) == @account_protocol, 0);
}

#[test]
#[expected_failure(abort_code = EInvalidVersionWitnessType)]
fun test_new_version_witness_rejects_non_version_type() {
    let _ = new(TestPackageWitness());
}
