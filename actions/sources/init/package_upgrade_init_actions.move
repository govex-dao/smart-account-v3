// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for package upgrade operations.
/// These specs can be staged into proposal outcomes or init flows.
module account_actions::package_upgrade_init_actions;

use account_actions::action_spec_builder;
use account_actions::package_upgrade;
use account_protocol::intents;
use std::string::String;
use sui::bcs;
use sui::object::ID;

// === Errors ===

const EEmptyPackageName: u64 = 0;
const EInvalidPolicy: u64 = 1;
const EEmptyResourceName: u64 = 2;

fun assert_valid_package_name(name: &String) {
    assert!(name.length() > 0, EEmptyPackageName);
}

fun assert_valid_policy(policy: u8) {
    assert!(package_upgrade::is_valid_restrict_policy(policy), EInvalidPolicy);
}

fun assert_valid_resource_name(resource_name: &String) {
    assert!(resource_name.length() > 0, EEmptyResourceName);
}

// === Layer 1: Action Structs ===

/// Action to authorize package upgrade.
public struct UpgradeAction has copy, drop, store {
    name: String,
    digest: vector<u8>,
    expected_cap_id: ID,
}

/// Action to commit an authorized package upgrade.
public struct CommitAction has copy, drop, store {
    name: String,
    expected_cap_id: ID,
}

/// Action to restrict package upgrade policy.
public struct RestrictAction has copy, drop, store {
    name: String,
    policy: u8,
    expected_cap_id: ID,
}

// === Layer 2: Spec Builders ===

/// Add a package-upgrade action spec.
public fun add_upgrade_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    digest: vector<u8>,
    expected_cap_id: ID,
) {
    assert_valid_package_name(&name);

    let action = UpgradeAction {
        name,
        digest,
        expected_cap_id,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::package_upgrade::package_upgrade_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add a package-commit action spec.
public fun add_commit_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    expected_cap_id: ID,
) {
    assert_valid_package_name(&name);

    let action = CommitAction {
        name,
        expected_cap_id,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::package_upgrade::package_commit_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add a package-restrict action spec.
public fun add_restrict_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    policy: u8,
    expected_cap_id: ID,
) {
    assert_valid_package_name(&name);
    assert_valid_policy(policy);

    let action = RestrictAction {
        name,
        policy,
        expected_cap_id,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::package_upgrade::package_restrict_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

}

/// Action to lock an UpgradeCap into the account via governance.
/// Binds the action to the exact UpgradeCap instance.
public struct LockUpgradeCapAction has copy, drop, store {
    name: String,
    delay_ms: u64,
    resource_name: String,
    expected_cap_id: ID,
}

/// Add a lock-upgrade-cap action spec bound to a specific UpgradeCap object.
/// The UpgradeCap must already be present in executable_resources under resource_name.
/// `expected_cap_id` is validated against the resource object during execution.
public fun add_lock_upgrade_cap_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    delay_ms: u64,
    resource_name: String,
    expected_cap_id: ID,
) {
    assert_valid_package_name(&name);
    assert_valid_resource_name(&resource_name);

    let action = LockUpgradeCapAction {
        name,
        delay_ms,
        resource_name,
        expected_cap_id,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::package_upgrade::lock_upgrade_cap_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

}

/// Action to unlock an UpgradeCap from the account into executable_resources.
public struct UnlockUpgradeCapAction has copy, drop, store {
    name: String,
    resource_name: String,
    expected_cap_id: ID,
}

/// Add an unlock-upgrade-cap action spec.
/// Removes the locked UpgradeCap, cleans up rules and index, and stores it in executable_resources.
public fun add_unlock_upgrade_cap_spec(
    builder: &mut action_spec_builder::Builder,
    name: String,
    resource_name: String,
    expected_cap_id: ID,
) {
    assert_valid_package_name(&name);
    assert_valid_resource_name(&resource_name);

    let action = UnlockUpgradeCapAction {
        name,
        resource_name,
        expected_cap_id,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::package_upgrade::unlock_upgrade_cap_marker(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

}

/// Convenience helper: stage upgrade and commit back-to-back for the same package.
public fun add_upgrade_and_commit_specs(
    builder: &mut action_spec_builder::Builder,
    name: String,
    digest: vector<u8>,
    expected_cap_id: ID,
) {
    add_upgrade_spec(builder, name, digest, expected_cap_id);
    add_commit_spec(builder, name, expected_cap_id);
}
