// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init action staging for currency operations during account initialization.
///
/// This module provides action structs and spec builders for staging currency actions.
/// Follows the 3-layer action execution pattern (see IMPORTANT_ACTION_EXECUTION_PATTERN.md)
module account_actions::currency_init_actions;

use account_protocol::intents;
use sui::object::ID;

// === Errors ===
const ESymbolImmutable: u64 = 1;
const EEmptyResourceName: u64 = 2;
const EResourceNameTooLong: u64 = 3;

const MAX_RESOURCE_NAME_LENGTH: u64 = 256;

fun assert_valid_resource_name(resource_name: &std::string::String) {
    assert!(resource_name.length() > 0, EEmptyResourceName);
    assert!(resource_name.length() <= MAX_RESOURCE_NAME_LENGTH, EResourceNameTooLong);
}

// === Action Structs (for BCS serialization) ===

/// Action to remove TreasuryCap into executable_resources.
/// PTB will call: currency::do_init_remove_treasury_cap_to_resources<...>(executable, ...)
public struct RemoveTreasuryCapToResourcesAction has copy, drop, store {
    expected_cap_id: ID,
    resource_name: std::string::String,
}

/// Action to remove MetadataCap into executable_resources.
/// PTB will call: currency::do_init_remove_metadata_cap_to_resources<...>(executable, ...)
public struct RemoveMetadataCapToResourcesAction has copy, drop, store {
    expected_cap_id: ID,
    resource_name: std::string::String,
}

/// Action to mint new coins and store in executable_resources
/// The minted coin can be consumed by subsequent actions (e.g., CreateVesting)
public struct MintAction has copy, drop, store {
    amount: u64,
    resource_name: std::string::String, // Output name in executable_resources
}

/// Action to mint a delegated CurrencyMintAdminCap into executable_resources.
public struct MintAdminCapAction has copy, drop, store {
    resource_name: std::string::String,
}

/// Action to burn coins from executable_resources
public struct BurnAction has copy, drop, store {
    amount: u64,
    resource_name: std::string::String, // Name of coin resource to burn
}

/// Action to update currency metadata
public struct UpdateAction has copy, drop, store {
    symbol: std::option::Option<vector<u8>>, // ASCII string
    name: std::option::Option<vector<u8>>, // UTF-8 string
    description: std::option::Option<vector<u8>>, // UTF-8 string
    icon_url: std::option::Option<vector<u8>>, // ASCII string
}

/// Action to lock TreasuryCap in account via governance.
/// TreasuryCap must be in executable_resources under resource_name
/// (via ProvideObjectToResources or OwnedWithdrawObject).
public struct LockTreasuryCapAction has copy, drop, store {
    has_max_supply: bool,
    max_supply: u64, // Only used if has_max_supply is true
    can_mint: bool,
    can_burn: bool,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
    resource_name: std::string::String,
}

/// Action to lock MetadataCap in account via governance.
/// MetadataCap must be in executable_resources under resource_name
/// (via ProvideObjectToResources or OwnedWithdrawObject).
public struct LockMetadataCapAction has copy, drop, store {
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
    resource_name: std::string::String,
}

// === Spec Builders ===

/// Add RemoveTreasuryCapToResourcesAction to Builder.
/// Follow this with a transfer/lock action that consumes the same resource_name.
public fun add_remove_treasury_cap_to_resources_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    expected_cap_id: ID,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;

    assert_valid_resource_name(&resource_name);

    let action = RemoveTreasuryCapToResourcesAction { expected_cap_id, resource_name };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_actions::currency::remove_treasury_cap_to_resources<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add RemoveMetadataCapToResourcesAction to Builder.
/// Follow this with a transfer/lock action that consumes the same resource_name.
public fun add_remove_metadata_cap_to_resources_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    expected_cap_id: ID,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;

    assert_valid_resource_name(&resource_name);

    let action = RemoveMetadataCapToResourcesAction { expected_cap_id, resource_name };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_actions::currency::remove_metadata_cap_to_resources<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add MintAction to Builder
/// Mints coins and stores them in executable_resources with the given resource_name
/// Subsequent actions (like CreateVesting) can consume from executable_resources
/// CoinType must match the TreasuryCap's coin type
public fun add_mint_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    amount: u64,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;


    let action = MintAction { amount, resource_name };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_actions::currency::currency_mint<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add BurnAction to Builder
/// Burns coins from executable_resources with the given resource_name
/// CoinType must match the coin type being burned
public fun add_burn_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    amount: u64,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;


    let action = BurnAction { amount, resource_name };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_actions::currency::currency_burn<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add MintAdminCapAction to Builder
/// Mints a CurrencyMintAdminCap<CoinType> into executable_resources with the given resource_name.
public fun add_mint_currency_admin_cap_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;


    let action = MintAdminCapAction { resource_name };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_actions::currency::mint_currency_admin_cap_marker<CoinType>(),
        action_data,
        1,
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add UpdateAction to Builder
/// CoinType must match the currency's coin type
public fun add_update_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    symbol: std::option::Option<vector<u8>>,
    name: std::option::Option<vector<u8>>,
    description: std::option::Option<vector<u8>>,
    icon_url: std::option::Option<vector<u8>>,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;


    // Symbol is immutable in the Currency standard - reject at staging time
    assert!(symbol.is_none(), ESymbolImmutable);

    let action = UpdateAction {
        symbol,
        name,
        description,
        icon_url,
    };
    let action_data = bcs::to_bytes(&action);

    let action_spec = intents::new_action_spec(
        account_actions::currency::currency_update<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

    // Convert Option<vector<u8>> to Option<String> for event emission
    let symbol_str = std::option::none<std::string::String>();
    let name_str = if (name.is_some()) {
        std::option::some(std::string::utf8(*name.borrow()))
    } else {
        std::option::none()
    };
    let description_str = if (description.is_some()) {
        std::option::some(std::string::utf8(*description.borrow()))
    } else {
        std::option::none()
    };
    let icon_url_str = if (icon_url.is_some()) {
        std::option::some(std::string::utf8(*icon_url.borrow()))
    } else {
        std::option::none()
    };

}

/// Add LockTreasuryCapAction to Builder
/// Used when a DAO wants to lock a TreasuryCap it acquired via governance.
/// TreasuryCap must be in executable_resources under resource_name at execution time.
/// CoinType must match the TreasuryCap's coin type.
public fun add_lock_treasury_cap_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    max_supply: std::option::Option<u64>,
    can_mint: bool,
    can_burn: bool,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;

    assert_valid_resource_name(&resource_name);


    // Serialize max_supply as has_max_supply + value
    let (has_max_supply, max_supply_value) = if (max_supply.is_some()) {
        (true, *max_supply.borrow())
    } else {
        (false, 0)
    };

    let action = LockTreasuryCapAction {
        has_max_supply,
        max_supply: max_supply_value,
        can_mint,
        can_burn,
        can_update_name,
        can_update_description,
        can_update_icon,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);

    // CRITICAL: Use marker type from currency module
    let action_spec = intents::new_action_spec(
        account_actions::currency::lock_treasury_cap_marker<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

}

/// Add LockMetadataCapAction to Builder
/// Used when a DAO wants to lock a MetadataCap it acquired via governance.
/// MetadataCap must be in executable_resources under resource_name at execution time.
/// CoinType must match the MetadataCap's coin type.
public fun add_lock_metadata_cap_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
    resource_name: std::string::String,
) {
    use account_actions::action_spec_builder;
    use sui::bcs;

    assert_valid_resource_name(&resource_name);


    let action = LockMetadataCapAction {
        can_update_name,
        can_update_description,
        can_update_icon,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);

    // CRITICAL: Use marker type from currency module
    let action_spec = intents::new_action_spec(
        account_actions::currency::lock_metadata_cap_marker<CoinType>(),
        action_data,
        1, // version
    );
    action_spec_builder::add(builder, action_spec);

}
