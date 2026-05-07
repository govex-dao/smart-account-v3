// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for access control operations.
/// These can be staged in intents for proposals or launchpad initialization.
///
/// Note:
/// - LockAction includes an `expected_id` to validate the cap being locked and a `resource_name`
///   to specify where to take it from executable_resources.
/// - UnlockToResourcesAction routes the cap into executable_resources.
module account_actions::access_control_init_actions;

use account_actions::action_spec_builder;
use account_protocol::intents;
use std::string::String;
use sui::bcs;
use sui::object::ID;

// === Layer 1: Action Structs ===

/// Action to lock a capability into the account.
/// expected_id validates the cap, resource_name specifies where to take it from executable_resources.
public struct LockAction has copy, drop, store {
    expected_id: ID,
    resource_name: String,
}

/// Action to unlock a capability into executable_resources.
/// The capability type is determined by the type parameter when calling do_unlock_to_resources
public struct UnlockToResourcesAction has copy, drop, store {
    /// ID of the locked cap governance approved for removal
    expected_id: ID,
    /// Name in executable_resources where the unlocked cap will be stored
    resource_name: String,
}

// === Layer 2: Spec Builder Functions ===

/// Add a lock action to the spec builder
/// Locks a capability into the account via governance action
/// Cap type must match the capability type to be locked
public fun add_lock_spec<Cap>(builder: &mut action_spec_builder::Builder, expected_id: ID, resource_name: String) {
    use account_actions::action_spec_builder as builder_mod;


    let action = LockAction { expected_id, resource_name };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::access_control::access_control_lock<Cap>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add an unlock-to-resources action to the spec builder.
/// Cap type must match the capability type to be unlocked
public fun add_unlock_to_resources_spec<Cap>(
    builder: &mut action_spec_builder::Builder,
    expected_id: ID,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = UnlockToResourcesAction { expected_id, resource_name };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::access_control::access_control_unlock_to_resources<Cap>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}
