// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Handles objects owned by the account address (Sui Transfer-To-Object pattern).
///
/// Anyone on Sui can `transfer::public_transfer` any object to any address, including
/// this account's object ID. Those objects land in the account's Receiving queue.
/// This module is the ONLY way to retrieve them.
///
/// Standard governance flow for coin recovery:
///   [OwnedWithdrawObject<Coin<T>>(resource_name="x"), VaultDepositObjectFromResources<T>(resource_name="x")]
///
/// For primary storage, prefer vault.move (fungible assets) and access_control.move (caps),
/// which use dynamic fields and are immune to RPC spam.

module account_protocol::owned;

public struct ExecutionProgressWitness has drop {}

use account_protocol::account::{Self, Account, Auth};
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents::{Self, PendingIntent};
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use std::type_name;
use sui::bcs;
use sui::event;
use sui::transfer::Receiving;

// === Imports ===

use fun account_protocol::intents::add_typed_action as PendingIntent.add_typed_action;

// === Errors ===

const EWrongObject: u64 = 0;
const EUnsupportedActionVersion: u64 = 3;

// === Events ===

/// Emitted when a WithdrawObject action is staged (added to intent)
public struct WithdrawObjectActionStaged has copy, drop {
    account_id: ID,
    object_id: ID,
    resource_name: String,
}

/// Emitted when an owned object is withdrawn from account (execution)
public struct ObjectWithdrawn has copy, drop {
    account_id: ID,
    object_id: ID,
    object_type: String,
    resource_name: String,
}

/// Emitted when an object is provided from PTB into executable_resources
public struct ObjectProvided has copy, drop {
    account_id: ID,
    object_id: ID,
    object_type: String,
    resource_name: String,
}

// === Action Type Markers ===

/// Withdraw owned object by ID (works for any object including Coin<T>)
/// phantom T locks the object type in the ActionSpec TypeName
public struct OwnedWithdrawObject<phantom T> has drop {}

/// Provide an object from PTB into executable_resources for subsequent actions.
/// phantom T locks the object type in the ActionSpec TypeName.
public struct ProvideObjectToResources<phantom T> has drop {}

/// Marker constructor for OwnedWithdrawObject.
public fun owned_withdraw_object<T>(): OwnedWithdrawObject<T> { OwnedWithdrawObject {} }

/// Marker constructor for ProvideObjectToResources
public fun provide_object_to_resources<T>(): ProvideObjectToResources<T> { ProvideObjectToResources {} }

// === Structs ===

/// Action guarding access to account owned objects which can only be received via this action
/// The object is stored in executable_resources under resource_name for subsequent actions
/// Note: This works for any object including Coin<T> - use OwnedWithdrawObject for all TTO recoveries
public struct WithdrawObjectAction has drop, store {
    // the owned object we want to access
    object_id: ID,
    // output name in executable_resources for subsequent actions
    resource_name: String,
}

// === Destruction Functions ===

/// Destroy a WithdrawObjectAction after serialization
public fun destroy_withdraw_object_action(action: WithdrawObjectAction) {
    let WithdrawObjectAction { object_id: _, resource_name: _ } = action;
}

// === Public functions ===

/// Creates a new WithdrawObjectAction and add it to an intent
/// The resource_name specifies where the object will be stored in executable_resources
/// for subsequent actions to consume (e.g., TransferObject)
public fun new_withdraw_object<Outcome, T: key + store, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    account: &Account,
    object_id: ID,
    resource_name: String,
    intent_witness: IW,
) {
    intents::pending_inner(intent).assert_is_account(account.addr());

    // Create the action struct
    let action = WithdrawObjectAction { object_id, resource_name };

    // Serialize it
    let action_data = bcs::to_bytes(&action);

    // Add to intent with pre-serialized bytes
    intent.add_typed_action(
        owned_withdraw_object<T>(),
        action_data,
        intent_witness,
    );

    event::emit(WithdrawObjectActionStaged {
        account_id: object::id(account),
        object_id,
        resource_name,
    });

    // Explicitly destroy the action struct
    destroy_withdraw_object_action(action);
}

/// Executes a WithdrawObjectAction and stores the object in executable_resources
/// SECURE: Object is stored in executable_resources under resource_name from ActionSpec
/// for consumption by subsequent actions (e.g., TransferObject)
public fun do_withdraw_object<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    receiving: Receiving<T>,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(account, registry, executable, ExecutionProgressWitness {});

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<OwnedWithdrawObject<T>>(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);
    let object_id = object::id_from_address(bcs::peel_address(&mut reader));
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed (prevent trailing data attacks)
    account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

    assert!(receiving.receiving_object_id() == object_id, EWrongObject);

    // Receive the object
    let obj = account::receive(account, receiving);

    // Store in executable_resources for subsequent actions to consume
    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        obj,
        ctx,
    );

    event::emit(ObjectWithdrawn {
        account_id: object::id(account),
        object_id,
        object_type: type_name::get<T>().into_string().to_string(),
        resource_name,
    });

    executable::increment_action_idx<_, OwnedWithdrawObject<T>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Takes an approved object from PTB params and stores it in executable_resources
/// under resource_name from ActionSpec. Subsequent actions can consume it by name
/// without each re-validating object identity.
///
/// ActionSpec data: expected_object_id (ID) ++ resource_name (String)
public fun do_provide_object<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    object: T,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(account, registry, executable, ExecutionProgressWitness {});

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<ProvideObjectToResources<T>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let expected_object_id = object::id_from_address(bcs::peel_address(&mut reader));
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    account_protocol::bcs_validation::validate_all_bytes_consumed(reader);

    let object_id = object::id(&object);
    assert!(object_id == expected_object_id, EWrongObject);

    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        object,
        ctx,
    );

    event::emit(ObjectProvided {
        account_id: object::id(account),
        object_id,
        object_type: type_name::get<T>().into_string().to_string(),
        resource_name,
    });

    executable::increment_action_idx<_, ProvideObjectToResources<T>, _>(executable, registry, ExecutionProgressWitness {});
}
