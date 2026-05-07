// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Stores capability objects (e.g. AdminCap, TreasuryCap) inside an Account as managed assets.
/// Provides governance-gated lock/unlock lifecycle so caps can be added or removed via proposals.
/// Lock validates the cap's object ID matches the expected_id approved by governance.
///
/// SECURITY: Caps are stored as dynamic fields on the Account. Action functions (do_*)
/// that need a cap remove it, use it, and return it within a single Move function call.
/// The cap is a local variable inside that call — it never appears as a PTB-level value,
/// so the transaction builder cannot route it to other commands.
///
/// Use a different Cap type for each privileged operation.

module account_actions::access_control;

public struct ExecutionProgressWitness has drop {}

use account_actions::actions_version as version;
use account_protocol::account::{Self, Account, Auth};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::bcs;
use sui::event;
use sui::object::{Self, ID};

// === Errors ===

/// Error when action version is not supported
const EUnsupportedActionVersion: u64 = 1;
const ECapIdMismatch: u64 = 2;
const EWrongAccount: u64 = 3;

// === Events ===

/// Emitted when a capability is locked into account (execution)
public struct CapLocked has copy, drop {
    account_id: ID,
    cap_type: TypeName,
}

/// Emitted when a capability is unlocked into executable_resources
public struct CapUnlocked has copy, drop {
    account_id: ID,
    cap_type: TypeName,
    resource_name: String,
}

// === Action Type Markers ===
// Cap type is encoded in the marker to prevent executor from operating on a different capability type

/// Lock capability into account
/// Cap type is encoded to ensure executor locks the intended capability type
public struct AccessControlLock<phantom Cap> has drop {}

/// Unlock capability into executable_resources.
/// Cap type is encoded to ensure executor unlocks the intended capability type.
public struct AccessControlUnlockToResources<phantom Cap> has drop {}

// === Action Type Marker Constructors ===

/// Creates a lock action type marker for use with intents::add_typed_action
public(package) fun access_control_lock<Cap>(): AccessControlLock<Cap> { AccessControlLock {} }

/// Creates an unlock-to-resources action marker for use with intents::add_typed_action
public(package) fun access_control_unlock_to_resources<Cap>(): AccessControlUnlockToResources<Cap> {
    AccessControlUnlockToResources {}
}

// === Structs ===

/// Dynamic Object Field key for the Cap.
public struct CapKey<phantom Cap>() has copy, drop, store;

/// Hot-potato proof that a specific cap was checked out of a specific account.
public struct CapReceipt<phantom Cap> {
    account_id: ID,
    cap_id: ID,
}

/// Returns the CapKey for a given Cap type. Package-internal to prevent privilege escalation.
/// External packages should use remove_cap / return_cap helpers for governance-approved flows.
public(package) fun cap_key<Cap>(): CapKey<Cap> { CapKey() }

/// Remove a capability from account via governance-approved Executable.
/// The returned receipt must be consumed by return_cap with the same cap object.
public fun remove_cap<Outcome: store, Cap: key + store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    executable: &Executable<Outcome>,
    action_witness: W,
): (Cap, CapReceipt<Cap>) {
    let account_id = object::id(account);
    let cap = account.remove_managed_asset(
        registry,
        CapKey<Cap>(),
        executable,
        action_witness,
    );
    let cap_id = object::id(&cap);
    (cap, CapReceipt<Cap> { account_id, cap_id })
}

/// Return a capability to account via governance-approved Executable.
/// Consumes the checkout receipt and rejects same-type cap substitution.
public fun return_cap<Outcome: store, Cap: key + store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: Cap,
    receipt: CapReceipt<Cap>,
    executable: &Executable<Outcome>,
    action_witness: W,
) {
    let CapReceipt { account_id, cap_id } = receipt;
    assert!(object::id(account) == account_id, EWrongAccount);
    assert!(object::id(&cap) == cap_id, ECapIdMismatch);

    account.add_managed_asset(
        registry,
        CapKey<Cap>(),
        cap,
        executable,
        action_witness,
    )
}

// === Public functions ===

/// Authenticated user can lock a Cap, the Cap must have at least store ability.
/// NOTE: Only used in tests. Production code uses actions.
#[test_only]
public fun lock_cap<Config: store, Cap: key + store>(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    cap: Cap,
) {
    account.verify(auth);
    account.add_managed_asset_with_package_witness(
        registry,
        CapKey<Cap>(),
        cap,
        version::current(),
    );
}

#[test_only]
/// Test-only version that bypasses initialized check.
/// Only use in tests where you need to lock caps on shared accounts for test setup.
public fun do_lock_cap_test_only<Cap: key + store>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: Cap,
) {
    account.add_managed_asset_with_package_witness(
        registry,
        CapKey<Cap>(),
        cap,
        version::current(),
    );
}

/// Checks if there is a Cap locked for a given type.
public fun has_lock<Config: store, Cap>(account: &Account): bool {
    account.has_managed_asset(CapKey<Cap>())
}

// === Intent functions ===

/// Locks a Cap into the Account via governance action (proposals or init intents).
/// Takes the cap from executable_resources (deposited by a prior ProvideObjectToResources action).
/// Stored under CapKey<Cap>. Other do_* functions can then remove/use/return it
/// within a single call (cap never exposed as a PTB-level value).
///
/// ActionSpec data: expected_id (ID) ++ resource_name (String)
public fun do_lock<Config: store, Outcome: store, Cap: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<AccessControlLock<Cap>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize expected_id and resource_name
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let expected_id = bcs::peel_address(&mut reader).to_id();
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // Take cap from executable_resources (deposited by prior ProvideObjectToResources action)
    let cap: Cap = account_protocol::executable_resources::take_object(
        executable, registry, ExecutionProgressWitness {}, resource_name,
    );

    // Verify the provided cap is the one governance approved
    assert!(object::id(&cap) == expected_id, ECapIdMismatch);

    account.add_managed_asset(
        registry,
        CapKey<Cap>(),
        cap,
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(CapLocked {
        account_id: object::id(account),
        cap_type: type_name::get<Cap>(),
    });

    executable::increment_action_idx<_, AccessControlLock<Cap>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Removes a Cap from the Account and stores it in executable_resources.
/// Remove + provide happen in one function call, so subsequent actions can consume the cap.
public fun do_unlock_to_resources<Config: store, Outcome: store, Cap: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec and verify it's an UnlockToResourcesAction
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<AccessControlUnlockToResources<Cap>>(action_spec);

    // Cap type is encoded in the marker and enforced by the typed increment below.

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize: expected_id, resource_name
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let expected_id = bcs::peel_address(&mut reader).to_id();
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed (security)
    bcs_validation::validate_all_bytes_consumed(reader);

    // Remove the cap and provide it into executable_resources for subsequent actions.
    let cap: Cap = account.remove_managed_asset(
        registry,
        CapKey<Cap>(),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(object::id(&cap) == expected_id, ECapIdMismatch);

    account_protocol::executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        cap,
        ctx,
    );

    event::emit(CapUnlocked {
        account_id: object::id(account),
        cap_type: type_name::get<Cap>(),
        resource_name,
    });

    // Increment the action index after all state writes authorized by this action.
    executable::increment_action_idx<_, AccessControlUnlockToResources<Cap>, _>(executable, registry, ExecutionProgressWitness {});
}
