// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Layer 1 & 2: Action structs and spec builders for vault operations.
/// These can be staged in intents for proposals or launchpad initialization.
module account_actions::vault_init_actions;

use account_actions::action_spec_builder;
use account_protocol::intents;
use std::string::String;
use sui::bcs;
use sui::object::ID;

// === Layer 1: Action Structs ===

/// Action to deposit coins to a vault
/// The resource_name specifies which coin to take from executable_resources
public struct DepositAction has copy, drop, store {
    vault_name: String,
    amount: u64,
    resource_name: String,
}

/// Action to spend/withdraw coins from a vault
/// The coin is placed in executable_resources under the given resource_name
/// for consumption by subsequent actions (e.g., TransferObject, Deposit)
public struct SpendAction has copy, drop, store {
    vault_name: String,
    amount: u64,
    spend_all: bool,
    resource_name: String,
}

/// Action to approve a coin type for deposits into a vault.
public struct ApproveCoinTypeAction has copy, drop, store {
    vault_name: String,
}

/// Action to remove a coin type approval from a vault.
public struct RemoveApprovedCoinTypeAction has copy, drop, store {
    vault_name: String,
}

/// Action to cancel a vesting stream.
/// Cancel removes stream metadata but does not move funds.
public struct CancelStreamAction has copy, drop, store {
    vault_name: String,
    stream_id: ID,
}

/// Action to collect vested tokens from a stream via governance.
/// Coins go to executable_resources under resource_name for subsequent actions.
/// StreamCap must be in executable_resources under cap_resource_name.
/// amount = 0 means collect all available.
public struct CollectStreamAction has copy, drop, store {
    vault_name: String,
    stream_id: ID,
    resource_name: String,
    amount: u64,
    cap_resource_name: String,
}

/// Action to deposit external coins (from PTB) into vault
/// Unlike DepositAction which takes from executable_resources,
/// this takes a coin directly from PTB but validates the amount
/// SECURITY: expected_amount is validated at execution time
public struct DepositExternalAction has copy, drop, store {
    vault_name: String,
    expected_amount: u64,
}

/// Action to deposit coins from executable_resources into a vault
///
/// SECURITY: This is safe because:
/// - Coins come from executable_resources (from prior governance-approved actions)
/// - Amount deposited = exactly what prior action produced (deterministic)
///
/// Use case: Deposit LP tokens, swap outputs, or other dynamic-amount coins
/// that are produced by a previous action in the proposal.
public struct DepositFromResourcesAction has copy, drop, store {
    vault_name: String, // Target vault
    resource_name: String, // Name in executable_resources
}

/// Action to deposit a Coin<T> object from executable_resources into a vault
///
/// This variant consumes from the object namespace instead of the coin namespace.
/// Use case: `owned::WithdrawObject<Coin<T>>` or other flows that stage a Coin object
/// via `provide_object`, then deposit it back into a vault.
public struct DepositObjectFromResourcesAction has copy, drop, store {
    vault_name: String, // Target vault
    resource_name: String, // Name in executable_resources object bag
}

/// Action to mint a VaultAdminCap for a specific vault.
/// The cap is placed in executable_resources under resource_name
/// for consumption by a subsequent action (e.g., CreateProtectiveBid).
public struct MintVaultAdminCapAction has copy, drop, store {
    vault_name: String,
    resource_name: String,
}

/// Action to open a new vault
/// The vault name must be unique within the account
public struct OpenVaultAction has copy, drop, store {
    vault_name: String,
}

/// Action to close an empty vault
/// The vault must have no balances and no active streams
public struct CloseVaultAction has copy, drop, store {
    vault_name: String,
}

// === Layer 2: Spec Builder Functions ===

/// Add a deposit action to the spec builder
/// The resource_name should match what the previous action (e.g., Mint) used
/// CoinType must match the type of coin being deposited
public fun add_deposit_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    amount: u64,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = DepositAction {
        vault_name,
        amount,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_deposit_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a spend action to the spec builder
/// The resource_name is used to store the coin in executable_resources
/// so subsequent actions can retrieve it (e.g., TransferObject uses this name)
/// CoinType must match the type of coin being spent
public fun add_spend_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    amount: u64,
    spend_all: bool,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = SpendAction {
        vault_name,
        amount,
        spend_all,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_spend_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add an approve-coin-type action to the spec builder.
/// CoinType must match the deposit type that governance is allowing for this vault.
public fun add_approve_coin_type_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = ApproveCoinTypeAction {
        vault_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_approve_coin_type_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a remove-coin-type-approval action to the spec builder.
/// Existing balances remain withdrawable; future deposits require re-approval.
public fun add_remove_approved_coin_type_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = RemoveApprovedCoinTypeAction {
        vault_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_remove_approved_coin_type_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a cancel stream action to the spec builder.
/// CoinType must match the stream's coin type
public fun add_cancel_stream_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    stream_id: ID,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = CancelStreamAction {
        vault_name,
        stream_id,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::cancel_stream_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a collect stream action to the spec builder.
/// Collects vested tokens from a stream via governance and routes to executable_resources.
/// StreamCap must be in executable_resources under cap_resource_name.
/// amount = 0 means collect all available.
/// CoinType must match the stream's coin type.
public fun add_collect_stream_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    stream_id: ID,
    resource_name: String,
    amount: u64,
    cap_resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = CollectStreamAction {
        vault_name,
        stream_id,
        resource_name,
        amount,
        cap_resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::collect_stream_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a deposit external action to the spec builder
/// This action takes a coin directly from PTB (not from executable_resources)
/// but validates that the coin amount matches expected_amount
///
/// Use case: Someone wants to donate/deposit coins as part of a governance proposal.
/// The expected amount is hardcoded at staging time, validated at execution.
/// Executor cannot substitute a different amount.
///
/// CoinType must match the type of coin being deposited
public fun add_deposit_external_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    expected_amount: u64,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = DepositExternalAction {
        vault_name,
        expected_amount,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_deposit_external_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a deposit from resources action to the spec builder
///
/// Deposits coins from executable_resources into specified vault.
/// Amount = exactly what prior action produced (deterministic).
///
/// CoinType must match the type of coin being deposited
/// vault_name is the target vault
/// resource_name must match what the previous action used to store the coin
public fun add_deposit_from_resources_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = DepositFromResourcesAction {
        vault_name,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_deposit_from_resources_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a deposit object from resources action to the spec builder
///
/// Deposits a `Coin<CoinType>` stored in executable_resources as an object into the specified vault.
/// This is used for object-path outputs such as `WithdrawObject<Coin<T>>`.
public fun add_deposit_object_from_resources_spec<CoinType>(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = DepositObjectFromResourcesAction {
        vault_name,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_deposit_object_from_resources_marker<CoinType>(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add an open vault action to the spec builder
/// Creates a new named vault. SUI deposits are approved by default; additional
/// deposit coin types are approved separately, except for vault names starting
/// with "donations".
/// The vault name must be unique within the account
public fun add_open_vault_spec(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = OpenVaultAction {
        vault_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_open_marker(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a close vault action to the spec builder
/// Removes an empty vault (must have no balances and no streams)
public fun add_close_vault_spec(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = CloseVaultAction {
        vault_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::vault_close_marker(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}

/// Add a mint vault admin cap action to the spec builder.
/// Mints a VaultAdminCap for the named vault and places it in executable_resources
/// under resource_name, so a subsequent action (e.g., CreateProtectiveBid) can consume it.
public fun add_mint_vault_admin_cap_spec(
    builder: &mut action_spec_builder::Builder,
    vault_name: String,
    resource_name: String,
) {
    use account_actions::action_spec_builder as builder_mod;


    let action = MintVaultAdminCapAction {
        vault_name,
        resource_name,
    };
    let action_data = bcs::to_bytes(&action);
    let action_spec = intents::new_action_spec(
        account_actions::vault::mint_vault_admin_cap_marker(),
        action_data,
        1,
    );
    builder_mod::add(builder, action_spec);

}
