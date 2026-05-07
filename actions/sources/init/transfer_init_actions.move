// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Init action staging for transfer operations
///
/// This module provides action structs and builders for:
/// - Direct object transfers (transfer module operations)
///
/// NOTE: For vault withdrawals + transfers, use the composable pattern:
/// 1. VaultSpend action (puts coin in executable_resources)
/// 2. TransferObject action (takes from executable_resources and transfers)
module account_actions::transfer_init_actions;

use account_protocol::intents;
use std::string::String;
use sui::bcs;

// === Errors ===
const EEmptyResourceName: u64 = 1;
const EUnknownResourceName: u64 = 3;

fun contains_subsequence(haystack: &vector<u8>, needle: &vector<u8>): bool {
    let hay_len = haystack.length();
    let needle_len = needle.length();
    if (needle_len == 0 || needle_len > hay_len) {
        return false
    };

    let mut i = 0;
    while (i + needle_len <= hay_len) {
        let mut j = 0;
        let mut matches = true;
        while (j < needle_len) {
            if (*haystack.borrow(i + j) != *needle.borrow(j)) {
                matches = false;
                break
            };
            j = j + 1;
        };
        if (matches) {
            return true
        };
        i = i + 1;
    };
    false
}

/// Best-effort cross-action validation: require this resource name to appear in prior staged data.
fun has_prior_resource_reference(
    builder: &account_actions::action_spec_builder::Builder,
    resource_name: &String,
): bool {
    let encoded_name = bcs::to_bytes(resource_name);
    let specs = account_actions::action_spec_builder::specs(builder);
    let mut i = 0;
    while (i < specs.length()) {
        let action_data = intents::action_spec_data(specs.borrow(i));
        if (contains_subsequence(action_data, &encoded_name)) {
            return true
        };
        i = i + 1;
    };
    false
}

// === Action Structs (for staging) ===

/// Action to transfer an object to a recipient
/// The resource_name specifies which object to take from executable_resources
public struct TransferObjectAction has copy, drop, store {
    recipient: address,
    resource_name: String,
}

/// Action to transfer an object to the transaction sender (cranker)
/// The resource_name specifies which object to take from executable_resources
public struct TransferToSenderAction has copy, drop, store {
    resource_name: String,
}

/// Action to transfer a coin to a recipient (uses take_coin key format)
/// Use this when the coin was provided via provide_coin (e.g., from VaultSpend, CurrencyMint)
public struct TransferCoinAction has copy, drop, store {
    recipient: address,
    resource_name: String,
}

/// Action to transfer a coin to the transaction sender (uses take_coin key format)
/// Use this for crank fees when the coin was provided via provide_coin
public struct TransferCoinToSenderAction has copy, drop, store {
    resource_name: String,
}

// === Spec Builders (for PTB construction) ===

/// Add a transfer object action to the spec builder
/// Used for transferring objects to a recipient
/// T must match the object type being transferred (encoded in marker for type safety)
/// The resource_name should match what the previous action (e.g., OwnedWithdraw) used
public fun add_transfer_object_spec<T: key + store>(
    builder: &mut account_actions::action_spec_builder::Builder,
    recipient: address,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(resource_name.length() > 0, EEmptyResourceName);
    assert!(has_prior_resource_reference(builder, &resource_name), EUnknownResourceName);


    let action = TransferObjectAction {
        recipient,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::transfer::transfer_object<T>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a transfer to sender action to the spec builder
/// The object will be transferred to whoever executes the intent (cranker)
/// T must match the object type being transferred (encoded in marker for type safety)
/// The resource_name should match what the previous action used
public fun add_transfer_to_sender_spec<T: key + store>(
    builder: &mut account_actions::action_spec_builder::Builder,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(resource_name.length() > 0, EEmptyResourceName);
    assert!(has_prior_resource_reference(builder, &resource_name), EUnknownResourceName);


    let action = TransferToSenderAction { resource_name };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::transfer::transfer_to_sender<T>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a transfer coin action to the spec builder
/// Use this when the coin was provided via provide_coin (e.g., from VaultSpend, CurrencyMint)
/// The resource_name should match what the previous action used
/// CoinType must match the coin type being transferred
public fun add_transfer_coin_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    recipient: address,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(resource_name.length() > 0, EEmptyResourceName);
    assert!(has_prior_resource_reference(builder, &resource_name), EUnknownResourceName);


    let action = TransferCoinAction { recipient, resource_name };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::transfer::transfer_coin<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a transfer coin to sender action to the spec builder
/// The coin will be transferred to whoever executes the intent (cranker)
/// Use this for crank fees when the coin was provided via provide_coin
/// The resource_name should match what the previous action used
/// CoinType must match the coin type being transferred
public fun add_transfer_coin_to_sender_spec<CoinType>(
    builder: &mut account_actions::action_spec_builder::Builder,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;

    assert!(resource_name.length() > 0, EEmptyResourceName);
    assert!(has_prior_resource_reference(builder, &resource_name), EUnknownResourceName);


    let action = TransferCoinToSenderAction { resource_name };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::transfer::transfer_coin_to_sender<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}
