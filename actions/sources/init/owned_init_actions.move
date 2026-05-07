// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for owned object operations.
/// These can be staged in intents for proposals or DAO initialization.
///
/// Used by the harmonized DAO creation pattern:
/// 1. Transfer object TO Account (becomes owned by Account)
/// 2. Stage WithdrawObject action (with object's ID)
/// 3. Stage processing action (Lock, Deposit, etc.)
/// 4. PTB executes: WithdrawObject receives object → executable_resources
///                  Processing action takes from executable_resources
module account_actions::owned_init_actions;

use account_actions::action_spec_builder;
use account_protocol::intents;
use std::string::String;
use sui::bcs;
use sui::object::ID;

// === Errors ===
const EEmptyResourceName: u64 = 1;

// === Layer 1: Action Structs ===

/// Action to withdraw an owned object from Account into executable_resources
/// The object_id is set at staging time - PTB must provide Receiving<T> for this exact object
/// This ensures determinism - PTB cannot substitute a different object
/// Note: This works for any object including Coin<T> - use for all TTO recoveries
public struct WithdrawObjectAction has copy, drop, store {
    object_id: ID,
    resource_name: String, // Where to store in executable_resources
}

/// Action to provide a PTB-level object into executable_resources.
/// The object_id is set at staging time so the executor cannot substitute a
/// different object of the same type.
public struct ProvideObjectAction has copy, drop, store {
    object_id: ID,
    resource_name: String,
}

// === Layer 2: Spec Builder Functions ===

/// Add a withdraw object action to the spec builder
/// Used by factory and launchpad for harmonized DAO creation
/// The object must be owned by the Account (transferred to Account address)
/// Object type is encoded in the marker type T
public fun add_withdraw_object_spec<T: key + store>(
    builder: &mut action_spec_builder::Builder,
    object_id: ID,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(resource_name.length() > 0, EEmptyResourceName);


    let action = WithdrawObjectAction {
        object_id,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);

    // Use marker type from owned module - T locks object type in ActionSpec TypeName
    let action_spec = intents::new_action_spec(
        account_protocol::owned::owned_withdraw_object<T>(),
        action_data,
        1, // version
    );
    builder_mod::add(builder, action_spec);

}

/// Add a provide-object-to-resources action to the spec builder.
/// Takes an approved object from PTB and stores it in executable_resources under resource_name.
/// Subsequent actions can consume it (e.g., AccessControlLock).
public fun add_provide_object_spec<T: key + store>(
    builder: &mut action_spec_builder::Builder,
    object_id: ID,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(resource_name.length() > 0, EEmptyResourceName);


    let action = ProvideObjectAction { object_id, resource_name };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_protocol::owned::provide_object_to_resources<T>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}
