// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Dependencies management for Accounts.
///
/// Two-tier authorization system:
/// 1. Global PackageRegistry - curated whitelist managed by protocol admins
/// 2. Per-Account Deps Table - custom packages each account can authorize
///
/// A package is authorized if it's in the global registry OR the per-account table.

module account_protocol::deps;

use account_protocol::package_registry::{Self, PackageRegistry};
use account_protocol::version_witness::{Self, VersionWitness};
use std::string::String;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};
use account_protocol::constants;

// === Errors ===

const ENotDep: u64 = 2;
const ERegistryMismatch: u64 = 7;
const EDepAlreadyExists: u64 = 8;
const EDepNotFound: u64 = 9;
const EInvalidAuthorizationLevel: u64 = 10;
const EAccountMismatch: u64 = 12;
const EAlreadyBound: u64 = 13;
const EDepNameAlreadyExists: u64 = 14;

// === Structs ===

/// Deps config stored in Account
/// The actual per-account table is stored as a dynamic field on the Account
public struct Deps has copy, drop, store {
    // ID of the PackageRegistry to use for global whitelist checking
    registry_id: ID,
    // Authorization level for action package validation:
    // 0 = GLOBAL_ONLY: Only global registry packages allowed
    // 1 = WHITELIST: Global registry OR per-account whitelist (default)
    // 2 = PERMISSIVE: Any action package allowed during staging/execution
    authorization_level: u8,
    // Defense-in-depth: ID of the Account that owns this Deps.
    // Set via bind_account_id() during Account::new().
    // Validated in authorization checks and add_dep
    // to prevent deps+account_deps from different Accounts being mixed.
    account_id: ID,
}

/// Key for the per-account deps Table dynamic field
public struct AccountDepsKey has copy, drop, store {}

/// Key for the dep names reverse index (name -> address) dynamic field
public struct DepNamesKey has copy, drop, store {}

/// Info stored for each package in the per-account table
public struct DepInfo has copy, drop, store {
    name: String,
    version: u64,
}

// === Public functions ===

/// Creates a new Deps struct with reference to the global registry.
/// Default authorization level is GLOBAL_ONLY (0).
/// Use new_with_level() to specify a different level.
public fun new(registry: &PackageRegistry): Deps {
    Deps {
        registry_id: sui::object::id(registry),
        authorization_level: constants::auth_level_global_only(),
        account_id: object::id_from_address(@0x0),
    }
}

/// Creates a new Deps struct with a specific authorization level.
public fun new_with_level(registry: &PackageRegistry, authorization_level: u8): Deps {
    assert!(authorization_level <= constants::auth_level_permissive(), EInvalidAuthorizationLevel);
    Deps {
        registry_id: sui::object::id(registry),
        authorization_level,
        account_id: object::id_from_address(@0x0),
    }
}

/// Creates an empty per-account deps table
public fun new_account_deps_table(ctx: &mut TxContext): Table<address, DepInfo> {
    table::new(ctx)
}

/// Returns the key for accessing the per-account deps table dynamic field
public fun account_deps_key(): AccountDepsKey {
    AccountDepsKey {}
}

/// Returns the key for accessing the dep names reverse index
public fun dep_names_key(): DepNamesKey {
    DepNamesKey {}
}

/// Creates an empty dep names reverse index
public fun new_dep_names_map(): VecMap<String, address> {
    vec_map::empty()
}

// === View functions ===

/// Strict authorization check. Unlike staging-time PERMISSIVE mode, strict
/// package-witness access never allows arbitrary packages. GLOBAL_ONLY allows
/// global registry packages; WHITELIST and PERMISSIVE also allow per-account deps.
public fun check_strict(
    deps: &Deps,
    version_witness: VersionWitness,
    registry: &PackageRegistry,
    account_deps: &Table<address, DepInfo>,
    account_id: ID,
) {
    assert!(deps.account_id == account_id, EAccountMismatch);
    assert!(deps.registry_id == sui::object::id(registry), ERegistryMismatch);

    let addr = version_witness.package_addr();

    if (package_registry::contains_package_addr(registry, addr)) return;

    if (deps.authorization_level == constants::auth_level_global_only()) {
        abort ENotDep
    };

    if (account_deps.contains(addr)) return;

    abort ENotDep
}

/// Returns the registry ID
public fun registry_id(deps: &Deps): ID {
    deps.registry_id
}

/// Returns the authorization level
public fun authorization_level(deps: &Deps): u8 {
    deps.authorization_level
}

/// Returns the bound account ID
public fun account_id(deps: &Deps): ID {
    deps.account_id
}

/// Bind this Deps to an Account. Can only be called once (account_id must be zero).
/// Called during Account::new() after the UID is created.
public(package) fun bind_account_id(deps: &mut Deps, account_id: ID) {
    assert!(deps.account_id == object::id_from_address(@0x0), EAlreadyBound);
    deps.account_id = account_id;
}

/// Returns constant for GLOBAL_ONLY level (0)
public fun auth_level_global_only(): u8 { constants::auth_level_global_only() }

/// Returns constant for WHITELIST level (1)
public fun auth_level_whitelist(): u8 { constants::auth_level_whitelist() }

/// Returns constant for PERMISSIVE level (2)
public fun auth_level_permissive(): u8 { constants::auth_level_permissive() }

/// Check if a package address is authorized based on authorization level.
/// This is used at staging time to validate action types before they can be added to proposals.
/// Returns true if authorized, false otherwise (does NOT abort).
///
/// Package authorization check used for intent staging and execution.
public fun is_package_authorized(
    deps: &Deps,
    registry: &PackageRegistry,
    account_deps: &Table<address, DepInfo>,
    package_addr: address,
    account_id: ID,
): bool {
    if (deps.account_id != account_id) {
        return false
    };
    if (deps.registry_id != sui::object::id(registry)) {
        return false
    };

    if (deps.authorization_level == constants::auth_level_permissive()) {
        return true
    };

    if (package_registry::contains_package_addr(registry, package_addr)) {
        return true
    };

    if (deps.authorization_level == constants::auth_level_global_only()) {
        return false
    };

    account_deps.contains(package_addr)
}


public fun assert_package_authorized(
    deps: &Deps,
    registry: &PackageRegistry,
    account_deps: &Table<address, DepInfo>,
    package_addr: address,
    account_id: ID,
) {
    assert!(deps.account_id == account_id, EAccountMismatch);
    assert!(deps.registry_id == sui::object::id(registry), ERegistryMismatch);
    assert!(
        is_package_authorized(
            deps,
            registry,
            account_deps,
            package_addr,
            account_id,
        ),
        ENotDep,
    );
}

// === Mutators (package-only) ===

/// Set the authorization level
public(package) fun set_authorization_level(deps: &mut Deps, level: u8) {
    assert!(level <= constants::auth_level_permissive(), EInvalidAuthorizationLevel);
    if (level == deps.authorization_level) return;
    deps.authorization_level = level;
}

/// Add a package to the per-account table.
/// For GLOBAL_ONLY level, the package must be in the global registry.
/// For WHITELIST and PERMISSIVE levels, any package can be added.
/// Names are unique so the reverse index remains unambiguous.
public fun add_dep(
    deps: &Deps,
    account_deps: &mut Table<address, DepInfo>,
    dep_names: &mut VecMap<String, address>,
    registry: &PackageRegistry,
    addr: address,
    name: String,
    version: u64,
    account_id: ID,
) {
    // Defense-in-depth: validate deps belong to this account
    assert!(deps.account_id == account_id, EAccountMismatch);
    // SECURITY: Validate registry matches stored ID to prevent fake registries
    assert!(deps.registry_id == sui::object::id(registry), ERegistryMismatch);

    assert!(!account_deps.contains(addr), EDepAlreadyExists);
    assert!(!dep_names.contains(&name), EDepNameAlreadyExists);

    // For GLOBAL_ONLY, package must be in global registry to add to account deps
    if (deps.authorization_level == constants::auth_level_global_only()) {
        assert!(registry.contains_package_addr(addr), ENotDep);
    };

    account_deps.add(addr, DepInfo { name, version });
    dep_names.insert(name, addr);
}

/// Add a package to the per-account table without registry authorization check.
/// IMPORTANT: Caller must verify authorization AND name uniqueness before calling this function.
/// This variant exists to avoid borrow conflicts when Account needs both &Deps and &mut Table.
/// See also: config::do_add_dep which performs authorization and name uniqueness checks.
public(package) fun add_dep_no_auth_check(
    account_deps: &mut Table<address, DepInfo>,
    addr: address,
    name: String,
    version: u64,
) {
    assert!(!account_deps.contains(addr), EDepAlreadyExists);
    account_deps.add(addr, DepInfo { name, version });
}

/// Remove a package from the per-account table
public fun remove_dep(account_deps: &mut Table<address, DepInfo>, addr: address): DepInfo {
    assert!(account_deps.contains(addr), EDepNotFound);
    account_deps.remove(addr)
}

/// Expose error constant for callers that enforce name uniqueness inline
public fun e_dep_name_already_exists(): u64 { EDepNameAlreadyExists }

/// Check if a package is in the per-account table
public fun contains_dep(account_deps: &Table<address, DepInfo>, addr: address): bool {
    account_deps.contains(addr)
}

/// Get dep info from per-account table
public fun get_dep(account_deps: &Table<address, DepInfo>, addr: address): &DepInfo {
    assert!(account_deps.contains(addr), EDepNotFound);
    account_deps.borrow(addr)
}

/// Get dep name
public fun dep_name(info: &DepInfo): String {
    info.name
}

/// Get dep version
public fun dep_version(info: &DepInfo): u64 {
    info.version
}

// === Test only ===

#[test_only]
use sui::test_utils::destroy;

#[test_only]
fun test_account_id(): ID {
    object::id_from_address(@0xACC)
}

#[test_only]
public fun new_for_testing(registry: &PackageRegistry, account_id: ID): Deps {
    Deps {
        registry_id: sui::object::id(registry),
        authorization_level: constants::auth_level_global_only(),
        account_id,
    }
}

#[test_only]
public fun new_for_testing_with_level(registry: &PackageRegistry, level: u8, account_id: ID): Deps {
    Deps {
        registry_id: sui::object::id(registry),
        authorization_level: level,
        account_id,
    }
}

// === Tests ===

#[test]
fun test_check_global_only(ctx: &mut TxContext) {
    let mut registry = package_registry::new_for_testing(ctx);

    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );

    let aid = test_account_id();
    let deps = new_for_testing(&registry, aid);
    let account_deps = new_account_deps_table(ctx);
    let witness = version_witness::new_for_testing(@account_protocol);

    // Should pass - in global registry
    deps.check_strict(witness, &registry, &account_deps, aid);

    destroy(registry);
    destroy(account_deps);
}

#[test]
fun test_check_per_account_only(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing_with_level(&registry, constants::auth_level_whitelist(), aid);

    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();

    // Add custom package to per-account table
    let custom_addr = @0xCAFE;
    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, custom_addr, b"CustomPkg".to_string(), 1, aid);

    let witness = version_witness::new_for_testing(custom_addr);

    // Should pass - in per-account table
    deps.check_strict(witness, &registry, &account_deps, aid);

    destroy(registry);
    destroy(account_deps);
}

#[test, expected_failure(abort_code = ENotDep)]
fun test_error_not_in_either(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing(&registry, aid);
    let account_deps = new_account_deps_table(ctx);

    let witness = version_witness::new_for_testing(@0xDEAD);

    // Should fail - not in global or per-account
    deps.check_strict(witness, &registry, &account_deps, aid);

    destroy(registry);
    destroy(account_deps);
}

#[test, expected_failure(abort_code = ERegistryMismatch)]
fun test_error_registry_mismatch(ctx: &mut TxContext) {
    let registry1 = package_registry::new_for_testing(ctx);
    let registry2 = package_registry::new_for_testing(ctx);

    let aid = test_account_id();
    let deps = new_for_testing(&registry1, aid);
    let account_deps = new_account_deps_table(ctx);
    let witness = version_witness::new_for_testing(@account_protocol);

    // Try to use different registry - should fail
    deps.check_strict(witness, &registry2, &account_deps, aid);

    destroy(registry1);
    destroy(registry2);
    destroy(account_deps);
}

#[test]
fun test_add_remove_dep(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing_with_level(&registry, constants::auth_level_whitelist(), aid);

    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();

    let addr = @0xCAFE;

    // Add
    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, addr, b"Test".to_string(), 1, aid);
    assert!(contains_dep(&account_deps, addr));

    // Get info
    let info = get_dep(&account_deps, addr);
    assert!(dep_name(info) == b"Test".to_string());
    assert!(dep_version(info) == 1);

    // Remove
    let removed = remove_dep(&mut account_deps, addr);
    assert!(!contains_dep(&account_deps, addr));
    assert!(dep_name(&removed) == b"Test".to_string());

    destroy(registry);
    destroy(account_deps);
}

#[test, expected_failure(abort_code = EDepAlreadyExists)]
fun test_error_add_duplicate(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing_with_level(&registry, constants::auth_level_whitelist(), aid);

    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();
    let addr = @0xCAFE;

    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, addr, b"Test".to_string(), 1, aid);
    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, addr, b"Test2".to_string(), 2, aid); // Should fail

    destroy(registry);
    destroy(account_deps);
}

#[test, expected_failure(abort_code = ENotDep)]
fun test_error_add_unverified_when_global_only(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing_with_level(&registry, constants::auth_level_global_only(), aid);

    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();
    let addr = @0xCAFE; // Not in global registry

    // Should fail - GLOBAL_ONLY mode and not in global registry
    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, addr, b"Test".to_string(), 1, aid);

    destroy(registry);
    destroy(account_deps);
}

#[test]
fun test_authorization_levels(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let mut deps = new_for_testing_with_level(&registry, constants::auth_level_global_only(), aid);

    // Start at GLOBAL_ONLY
    assert!(deps.authorization_level() == constants::auth_level_global_only());

    // Set to WHITELIST
    set_authorization_level(&mut deps, constants::auth_level_whitelist());
    assert!(deps.authorization_level() == constants::auth_level_whitelist());

    // Set to PERMISSIVE
    set_authorization_level(&mut deps, constants::auth_level_permissive());
    assert!(deps.authorization_level() == constants::auth_level_permissive());

    destroy(registry);
}

#[test]
fun test_permissive_mode_allows_any_package(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing_with_level(&registry, constants::auth_level_permissive(), aid);
    let account_deps = new_account_deps_table(ctx);

    let random_addr = @0xDEADBEEF; // Not in registry or account deps

    // PERMISSIVE mode should authorize any package
    assert!(is_package_authorized(&deps, &registry, &account_deps, random_addr, aid));

    destroy(registry);
    destroy(account_deps);
}

#[test]
fun test_global_only_mode_rejects_account_deps(ctx: &mut TxContext) {
    let mut registry = package_registry::new_for_testing(ctx);

    // Add a package to global registry
    let global_addr = @0x1111;
    package_registry::add_for_testing(&mut registry, b"GlobalPkg".to_string(), global_addr, 1);

    let aid = test_account_id();
    // Use WHITELIST mode to add a package to account deps
    let deps_whitelist = new_for_testing_with_level(&registry, constants::auth_level_whitelist(), aid);
    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();
    let account_addr = @0x2222;
    add_dep(
        &deps_whitelist,
        &mut account_deps,
        &mut dep_names,
        &registry,
        account_addr,
        b"AccountPkg".to_string(),
        1,
        aid,
    );

    // Now switch to GLOBAL_ONLY mode
    let deps_global = new_for_testing_with_level(&registry, constants::auth_level_global_only(), aid);

    // Global package should be authorized
    assert!(is_package_authorized(&deps_global, &registry, &account_deps, global_addr, aid));

    // Account-only package should NOT be authorized in GLOBAL_ONLY mode
    assert!(!is_package_authorized(&deps_global, &registry, &account_deps, account_addr, aid));

    destroy(registry);
    destroy(account_deps);
}

#[test, expected_failure(abort_code = ENotDep)]
fun test_check_global_only_rejects_account_only_dep(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);

    let aid = test_account_id();
    let deps_whitelist = new_for_testing_with_level(&registry, constants::auth_level_whitelist(), aid);
    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();
    let account_addr = @0x2222;
    add_dep(
        &deps_whitelist,
        &mut account_deps,
        &mut dep_names,
        &registry,
        account_addr,
        b"AccountPkg".to_string(),
        1,
        aid,
    );

    let deps_global = new_for_testing_with_level(&registry, constants::auth_level_global_only(), aid);
    let witness = version_witness::new_for_testing(account_addr);
    deps_global.check_strict(witness, &registry, &account_deps, aid);

    destroy(registry);
    destroy(account_deps);
}

#[test]
fun test_add_dep_verified_in_global_registry(ctx: &mut TxContext) {
    // Test that we can add a dep to per-account table even when GLOBAL_ONLY
    // if the package IS in the global registry
    let mut registry = package_registry::new_for_testing(ctx);

    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );

    let aid = test_account_id();
    let deps = new_for_testing(&registry, aid); // GLOBAL_ONLY

    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();

    // Should succeed - package is in global registry, so allowed even with GLOBAL_ONLY
    add_dep(
        &deps,
        &mut account_deps,
        &mut dep_names,
        &registry,
        @account_protocol,
        b"AccountProtocol".to_string(),
        1,
        aid,
    );
    assert!(contains_dep(&account_deps, @account_protocol), 0);

    destroy(registry);
    destroy(account_deps);
}

#[test, expected_failure(abort_code = EDepNameAlreadyExists)]
fun test_error_add_duplicate_name(ctx: &mut TxContext) {
    let registry = package_registry::new_for_testing(ctx);
    let aid = test_account_id();
    let deps = new_for_testing_with_level(&registry, constants::auth_level_whitelist(), aid);

    let mut account_deps = new_account_deps_table(ctx);
    let mut dep_names = new_dep_names_map();

    // Add first package
    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, @0xCAFE, b"SameName".to_string(), 1, aid);
    // Add second package with SAME name but different address - should fail
    add_dep(&deps, &mut account_deps, &mut dep_names, &registry, @0xBEEF, b"SameName".to_string(), 1, aid);

    destroy(registry);
    destroy(account_deps);
}
