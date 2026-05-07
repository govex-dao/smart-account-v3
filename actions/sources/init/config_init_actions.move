// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for config operations.
/// These can be staged in intents for proposals.
///
/// Contains actions for per-account dependencies management:
/// - SetAuthorizationLevel: Set the authorization level for action package validation
/// - AddDep: Add a package to the per-account deps table
/// - RemoveDep: Remove a package from the per-account deps table
module account_actions::config_init_actions;

use account_actions::action_spec_builder;
use account_protocol::constants;
use account_protocol::intents;
use std::string::String;
use sui::bcs;

// === Errors ===
const EInvalidAuthLevel: u64 = 1;
const EEmptyName: u64 = 2;
const EZeroAddress: u64 = 3;
const EActionDataTooLarge: u64 = 4;

// === Layer 1: Action Structs ===

/// Action to set the authorization level for action package validation.
/// Level 0 = GLOBAL_ONLY: Only global registry packages allowed
/// Level 1 = WHITELIST: Global registry OR per-account whitelist
/// Level 2 = PERMISSIVE: Any package allowed (no checks)
public struct SetAuthorizationLevelAction has copy, drop, store {
    level: u8,
}

/// Action to add a package to the per-account deps table.
/// For GLOBAL_ONLY level, the package must be in the global registry.
public struct AddDepAction has copy, drop, store {
    /// The package address to add
    addr: address,
    /// The package name (for reference only)
    name: String,
    /// The package version
    version: u64,
}

/// Action to remove a package from the per-account deps table.
public struct RemoveDepAction has copy, drop, store {
    /// The package address to remove
    addr: address,
}

// === Layer 2: Spec Builder Functions ===

/// Add a set authorization level action to the spec builder.
/// This sets the authorization level for action package validation:
/// - Level 0 (GLOBAL_ONLY): Only packages in global registry can be staged/executed
/// - Level 1 (WHITELIST): Global registry OR per-account whitelist packages allowed
/// - Level 2 (PERMISSIVE): Any package can be staged/executed (no checks)
public fun add_set_authorization_level_spec(builder: &mut action_spec_builder::Builder, level: u8) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(level <= 2, EInvalidAuthLevel);


    let action = SetAuthorizationLevelAction { level };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_protocol::config::config_set_authorization_level(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add an add dep action to the spec builder.
/// This adds a package to the per-account deps table, allowing it to be used
/// for action execution on this account.
///
/// For GLOBAL_ONLY level, the package must exist in the global PackageRegistry.
public fun add_add_dep_spec(
    builder: &mut action_spec_builder::Builder,
    addr: address,
    name: String,
    version: u64,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(name.length() > 0, EEmptyName);
    assert!(addr != @0x0, EZeroAddress);


    let action = AddDepAction {
        addr,
        name,
        version,
    };
    let action_data = bcs::to_bytes(&action);
    assert!(action_data.length() <= constants::max_action_data_size(), EActionDataTooLarge);
    let action_spec = intents::new_action_spec(
        account_protocol::config::config_add_dep(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a remove dep action to the spec builder.
/// This removes a package from the per-account deps table.
public fun add_remove_dep_spec(builder: &mut action_spec_builder::Builder, addr: address) {
    use account_actions::action_spec_builder as builder_mod;


    let action = RemoveDepAction {
        addr,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_protocol::config::config_remove_dep(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}
