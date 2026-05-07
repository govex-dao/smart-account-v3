// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This module allows to manage Account settings.
/// The actions are related to the modifications of certain fields of the Account
/// (metadata, deps, authorization levels).
/// All these fields are encapsulated in the `Account` struct and each managed in
/// their own module.
/// They are only accessible mutably via package functions defined in account.move
/// which are used here only.

module account_protocol::config;

public struct ExecutionProgressWitness has drop {}

use account_protocol::account::{Self, Account};
use account_protocol::deps::{Self};
use account_protocol::executable::Executable;
use account_protocol::package_registry::{Self, PackageRegistry};
use std::string::{Self, String};
use sui::bcs::{Self};
use sui::event;

// === Error Constants ===

/// Error when action version is not supported
const EUnsupportedActionVersion: u64 = 1;
/// Error when package is not authorized (not in global registry and authorization level is GLOBAL_ONLY)
const EPackageNotAuthorized: u64 = 10;
/// Error when authorization level is outside the supported range [0..2]
const EInvalidAuthorizationLevel: u64 = 11;

// === Events ===

/// Emitted when authorization level is changed (execution)
public struct AuthorizationLevelChanged has copy, drop {
    account_id: ID,
    new_level: u8,
}

/// Emitted when a package is added to per-account deps (execution)
public struct DepAdded has copy, drop {
    account_id: ID,
    package_addr: address,
    package_name: String,
    version: u64,
}

/// Emitted when a package is removed from per-account deps (execution)
public struct DepRemoved has copy, drop {
    account_id: ID,
    package_addr: address,
}

// === Action Type Markers ===

/// Set authorization level for action package validation
public struct ConfigSetAuthorizationLevel has drop {}
/// Add package to per-account deps
public struct ConfigAddDep has drop {}
/// Remove package from per-account deps
public struct ConfigRemoveDep has drop {}

public fun config_set_authorization_level(): ConfigSetAuthorizationLevel {
    ConfigSetAuthorizationLevel {}
}

public fun config_add_dep(): ConfigAddDep { ConfigAddDep {} }

public fun config_remove_dep(): ConfigRemoveDep { ConfigRemoveDep {} }

// === Structs ===

/// Intent Witness for setting authorization level
public struct SetAuthorizationLevelIntent() has drop;
/// Intent Witness for adding a dep
public struct AddDepIntent() has drop;
/// Intent Witness for removing a dep
public struct RemoveDepIntent() has drop;

/// Action to set the authorization level for action package validation
/// Level 0 = GLOBAL_ONLY, Level 1 = WHITELIST, Level 2 = PERMISSIVE
public struct SetAuthorizationLevelAction has copy, drop, store {
    level: u8,
}

/// Action to add a package to the per-account deps table
public struct AddDepAction has copy, drop, store {
    addr: address,
    name: String,
    version: u64,
}

/// Action to remove a package from the per-account deps table
public struct RemoveDepAction has copy, drop, store {
    addr: address,
}

// === Public Constructors for Actions ===

/// Create a new SetAuthorizationLevelAction
/// Level 0 = GLOBAL_ONLY, Level 1 = WHITELIST, Level 2 = PERMISSIVE
public fun new_set_authorization_level_action(level: u8): SetAuthorizationLevelAction {
    assert!(
        level <= account_protocol::constants::auth_level_permissive(),
        EInvalidAuthorizationLevel,
    );
    SetAuthorizationLevelAction { level }
}

// ============================================================================
// === Per-Account Dependencies Management (3-Layer Pattern) ===
// ============================================================================

// --- Set Authorization Level ---

/// Executes an action to set the authorization level for action package validation
/// Level 0 = GLOBAL_ONLY: Only global registry packages allowed
/// Level 1 = WHITELIST: Global registry OR per-account whitelist
/// Level 2 = PERMISSIVE: Any package allowed (no checks)
public fun do_set_authorization_level<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    // Get ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<ConfigSetAuthorizationLevel>(action_spec);

    // Check version
    let spec_version = account_protocol::intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Get BCS bytes from ActionSpec and deserialize the level
    let action_data = account_protocol::intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let level = bcs::peel_u8(&mut reader);

    // Validate all bytes consumed
    account_protocol::bcs_validation::validate_all_bytes_consumed(reader);
    assert!(
        level <= account_protocol::constants::auth_level_permissive(),
        EInvalidAuthorizationLevel,
    );

    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // Set the authorization level only when it changes policy semantics.
    if (level != account.deps().authorization_level()) {
        let deps_ref = account::deps_mut(
            account,
            registry,
            executable,
            ExecutionProgressWitness {},
        );
        deps::set_authorization_level(deps_ref, level);

        event::emit(AuthorizationLevelChanged {
            account_id: object::id(account),
            new_level: level,
        });
    };

    // Increment action index
    account_protocol::executable::increment_action_idx<_, ConfigSetAuthorizationLevel, _>(executable, registry, ExecutionProgressWitness {});
}

// --- Add Dep ---

/// Executes an action to add a package to the per-account deps table
/// For GLOBAL_ONLY, the package must be in the global registry
public fun do_add_dep<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // Get ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<ConfigAddDep>(action_spec);

    // Check version
    let spec_version = account_protocol::intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize action
    let action_data = account_protocol::intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let addr = bcs::peel_address(&mut reader);
    let name = string::utf8(bcs::peel_vec_u8(&mut reader));
    let dep_version = bcs::peel_u64(&mut reader);

    // Validate all bytes consumed
    account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

    let auth_level = account.deps().authorization_level();
    if (auth_level == deps::auth_level_global_only()) {
        assert!(
            package_registry::contains_package_addr(registry, addr),
            EPackageNotAuthorized,
        );
    };

    // Enforce name uniqueness so the reverse index remains unambiguous.
    // Sequential borrows to avoid borrow conflict on Account.
    let dep_names = account::dep_names_mut(account);
    assert!(!dep_names.contains(&name), deps::e_dep_name_already_exists());
    dep_names.insert(name, addr);

    // Add to per-account table (auth check and name check already done above)
    let account_deps = account::account_deps_mut(account);
    deps::add_dep_no_auth_check(
        account_deps,
        addr,
        name,
        dep_version,
    );

    event::emit(DepAdded {
        account_id: object::id(account),
        package_addr: addr,
        package_name: name,
        version: dep_version,
    });

    // Increment action index
    account_protocol::executable::increment_action_idx<_, ConfigAddDep, _>(executable, registry, ExecutionProgressWitness {});
}

// --- Remove Dep ---

/// Executes an action to remove a package from the per-account deps table
public fun do_remove_dep<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    account::assert_execution_authorized(
        account,
        registry,
        executable,
        ExecutionProgressWitness {},
    );

    // Get ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<ConfigRemoveDep>(action_spec);

    // Check version
    let spec_version = account_protocol::intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize action
    let action_data = account_protocol::intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let addr = bcs::peel_address(&mut reader);

    // Validate all bytes consumed
    account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

    // Remove the dep from per-account table
    let removed = deps::remove_dep(account::account_deps_mut(account), addr);

    // Clean up name from reverse index (sequential borrow).
    // Missing reverse-index state fails closed to preserve name uniqueness guarantees.
    let removed_name = deps::dep_name(&removed);
    let dep_names = account::dep_names_mut(account);
    if (dep_names.contains(&removed_name)) {
        dep_names.remove(&removed_name);
    };

    event::emit(DepRemoved {
        account_id: object::id(account),
        package_addr: addr,
    });

    // Increment action index
    account_protocol::executable::increment_action_idx<_, ConfigRemoveDep, _>(executable, registry, ExecutionProgressWitness {});
}
