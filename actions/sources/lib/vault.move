// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

module account_actions::vault;

public struct ExecutionProgressWitness has drop {}

use account_actions::actions_version as version;
use account_actions::stream_utils;
use account_actions::actions_constants;
use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::{Self, PackageRegistry};
use std::option::Option;
use std::string::String;
use std::type_name::{Self, TypeName};
use std::u64;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::transfer;


// === Errors ===

const EVaultNotEmpty: u64 = 0;
const EStreamNotFound: u64 = 1;
const EStreamNotStarted: u64 = 2;
const EStreamCapMismatch: u64 = 37;
const EWrongCoinType: u64 = 5;
const EInsufficientVestedAmount: u64 = 8;
const EInvalidStreamParameters: u64 = 9;
const EIntentAmountMismatch: u64 = 10;
const EAmountMustBeGreaterThanZero: u64 = 20;
const EVaultDoesNotExist: u64 = 21;
const ECoinTypeDoesNotExist: u64 = 22;
const EInsufficientBalance: u64 = 23;
const EUnsupportedActionVersion: u64 = 17;
const EArithmeticOverflow: u64 = 24;
const ETooManyVaults: u64 = 33;
const EVaultAlreadyExists: u64 = 34;
const EZeroBeneficiary: u64 = 35;
const EStreamStillActive: u64 = 36;
const EAdminCapAccountMismatch: u64 = 38;
const ERecipientNotWhitelisted: u64 = 39;
const ESpendingLimitNotFound: u64 = 40;
const ESpendingLimitExpired: u64 = 41;
const ESpendingCapMismatch: u64 = 42;
const EInsufficientSpendingBudget: u64 = 43;
const ESpendingLimitStillActive: u64 = 44;
const EEmptyWhitelist: u64 = 45;
const ESpendingLimitNotStarted: u64 = 46;
const ECoinTypeNotApproved: u64 = 47;
const ESpendingLimitNotExpired: u64 = 48;
const ESpendingLimitNoExpiry: u64 = 49;
const EExpiryNotSupportedForStream: u64 = 50;
const ETooManyRecipients: u64 = 51;
const EZeroWhitelistRecipient: u64 = 52;
const EDuplicateWhitelistRecipient: u64 = 53;

// === Vault Constants ===

/// Canonical name for the treasury vault.
public fun treasury_vault(): vector<u8> { b"treasury" }

// === Action Type Markers ===

/// Deposit coins into vault
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct VaultDeposit<phantom CoinType> has drop {}

/// Spend coins from vault
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct VaultSpend<phantom CoinType> has drop {}

/// Approve a coin type for deposits into a vault.
/// CoinType is encoded in the marker to prevent executor from changing coin type.
public struct VaultApproveCoinType<phantom CoinType> has drop {}

/// Remove a coin type approval from a vault.
/// Existing balances remain withdrawable, but new deposits require re-approval.
public struct VaultRemoveApprovedCoinType<phantom CoinType> has drop {}


/// Cancel stream
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct CancelStream<phantom CoinType> has drop {}

/// Create stream (marker type for action validation)
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct CreateStream<phantom CoinType> has drop {}

/// Collect from stream (marker type for action validation)
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct CollectStream<phantom CoinType> has drop {}


/// Deposit external coins into vault (from PTB, not executable_resources)
/// CoinType is encoded in the marker to prevent executor from changing coin type
/// Amount is validated at execution to match staged amount
public struct VaultDepositExternal<phantom CoinType> has drop {}

/// Deposit coins from executable_resources into vault (harmonized pattern)
/// CoinType is encoded in the marker to prevent executor from changing coin type
/// Takes coin from executable_resources (put there by WithdrawCoin action)
public struct VaultDepositFromResources<phantom CoinType> has drop {}

/// Deposit a Coin<CoinType> object from executable_resources into vault.
/// Uses take_object<Coin<CoinType>> instead of take_coin<CoinType> to match
/// the object_key format used by WithdrawObjectAction's provide_object.
/// This bridges TTO coin recovery (provide_object) → vault deposit (take_object).
public struct VaultDepositObjectFromResources<phantom CoinType> has drop {}

/// Open a new vault (governance action)
/// No CoinType needed - deposit coin types are approved separately
public struct VaultOpen has drop {}

/// Close an empty vault (governance action)
/// No CoinType needed - vault must be empty to close
public struct VaultClose has drop {}

/// Mint a VaultAdminCap (governance action)
/// Grants cap-gated withdrawal from a specific vault
public struct MintVaultAdminCap has drop {}

// === Factory Functions for Generic Marker Types ===
/// SECURITY: Package-private to prevent external code from obtaining drop-typed values
/// that could bypass package-witness authorization checks.

/// Create a VaultDeposit marker
public(package) fun vault_deposit_marker<CoinType>(): VaultDeposit<CoinType> { VaultDeposit {} }

/// Create a VaultSpend marker
public(package) fun vault_spend_marker<CoinType>(): VaultSpend<CoinType> { VaultSpend {} }

/// Create a VaultApproveCoinType marker
public(package) fun vault_approve_coin_type_marker<CoinType>(): VaultApproveCoinType<CoinType> {
    VaultApproveCoinType {}
}

/// Create a VaultRemoveApprovedCoinType marker
public(package) fun vault_remove_approved_coin_type_marker<CoinType>(): VaultRemoveApprovedCoinType<CoinType> {
    VaultRemoveApprovedCoinType {}
}


/// Create a CancelStream marker
public(package) fun cancel_stream_marker<CoinType>(): CancelStream<CoinType> { CancelStream {} }

/// Create a CreateStream marker
public(package) fun create_stream_marker<CoinType>(): CreateStream<CoinType> { CreateStream {} }

/// Create a CollectStream marker
public(package) fun collect_stream_marker<CoinType>(): CollectStream<CoinType> { CollectStream {} }


/// Create a VaultDepositExternal marker
public(package) fun vault_deposit_external_marker<CoinType>(): VaultDepositExternal<CoinType> {
    VaultDepositExternal {}
}

/// Create a VaultDepositFromResources marker
public(package) fun vault_deposit_from_resources_marker<CoinType>(): VaultDepositFromResources<CoinType> {
    VaultDepositFromResources {}
}

/// Create a VaultDepositObjectFromResources marker
public(package) fun vault_deposit_object_from_resources_marker<CoinType>(): VaultDepositObjectFromResources<CoinType> {
    VaultDepositObjectFromResources {}
}

/// Create a VaultOpen marker
/// SECURITY: Package-private to prevent external code from obtaining drop-typed values
/// that could bypass package-witness authorization checks.
public(package) fun vault_open_marker(): VaultOpen { VaultOpen {} }

/// Create a VaultClose marker
public(package) fun vault_close_marker(): VaultClose { VaultClose {} }

/// Create a MintVaultAdminCap marker
public(package) fun mint_vault_admin_cap_marker(): MintVaultAdminCap { MintVaultAdminCap {} }

// === Structs ===

/// Capability object for stream beneficiaries. 1:1 with VaultStream.
/// Transferred to beneficiary on stream creation.
/// Borrowed for CollectStream authorization.
public struct StreamCap has key, store {
    id: UID,
    stream_id: ID,
    account_id: ID,
    account_addr: address,
    vault_name: String,
}

/// Capability for spending limit delegates. 1:1 with a VaultStream that has
/// non-empty whitelisted_recipients. Transferred to delegate on creation.
/// Holder calls `spend_with_cap` to send funds to whitelisted addresses.
public struct SpendingCap has key, store {
    id: UID,
    spending_limit_id: ID,
    account_id: ID,
    account_addr: address,
    vault_name: String,
}

/// Capability granting cap-gated withdrawal from a specific vault on a specific account.
/// Created via MintVaultAdminCap governance action. Stored inside consumer objects
/// (e.g. ProtectiveBid) so they can withdraw without governance per-transaction.
public struct VaultAdminCap has key, store {
    id: UID,
    vault_name: String,
    account_id: ID,
}

/// Dynamic Field key for the Vault.
public struct VaultKey(String) has copy, drop, store;
/// Dynamic Field key for the vault names registry (tracks all vault names)
public struct VaultNamesKey has copy, drop, store {}
/// Dynamic field holding a budget with different coin types, key is name
public struct Vault has store {
    // heterogeneous array of Balances, TypeName -> Balance<CoinType>
    bag: Bag,
    // approved deposit coin types; donations* vaults bypass this allowlist
    approved_types: vector<TypeName>,
    // streams for time-based vesting withdrawals
    streams: Table<ID, VaultStream>,
}

/// Stream for iteration-based vesting from vault
/// Features:
/// - Iteration-based vesting (discrete unlock events)
/// - Optional "use or lose" claim window per iteration
/// - Always cancellable by DAO governance (cancel & recreate to modify)
///
/// Note: For immutable vestings with beneficiary control, use the standalone
/// vesting module instead. Vault streams are simple DAO-controlled streams.
public struct VaultStream has drop, store {
    id: ID,
    coin_type: TypeName,
    // Core vesting parameters (iteration-based)
    amount_per_iteration: u64, // Tokens that unlock per iteration (NO DIVISION!)
    claimed_amount: u64, // Total claimed so far
    first_unclaimed_iteration: u64, // First iteration not yet fully claimed (window tracking)
    partial_claimed_in_iteration: u64, // Partial claim within first_unclaimed_iteration
    start_time: u64,
    iterations_total: u64, // Number of unlock events
    iteration_period_ms: u64, // Time between unlocks (ms)
    // Use-or-lose feature
    claim_window_ms: Option<u64>, // If Some(X), must claim within X ms after unlock or forfeit
    // Spending limit fields (empty = regular stream, non-empty = spending limit)
    whitelisted_recipients: vector<address>, // Allowed destinations for spend_with_cap
    expiry_ms: Option<u64>, // Optional hard expiry timestamp
}

// Event structures for vault operations (execution)

/// Emitted when coins are deposited to vault
public struct VaultDeposited has copy, drop {
    account_id: ID,
    vault_name: String,
    coin_type: TypeName,
    amount: u64,
}

/// Emitted when coins are spent from vault
public struct VaultSpent has copy, drop {
    account_id: ID,
    vault_name: String,
    coin_type: TypeName,
    amount: u64,
    resource_name: String,
}


/// Emitted when a new vault is opened
public struct VaultOpened has copy, drop {
    account_id: ID,
    vault_name: String,
}

/// Emitted when a vault is closed
public struct VaultClosed has copy, drop {
    account_id: ID,
    vault_name: String,
}

/// Emitted when a vault approves a coin type for deposits.
public struct CoinTypeApproved has copy, drop {
    account_id: ID,
    vault_name: String,
    coin_type: TypeName,
}

/// Emitted when a vault removes a coin type approval.
public struct CoinTypeApprovalRemoved has copy, drop {
    account_id: ID,
    vault_name: String,
    coin_type: TypeName,
}

// Event structures for stream operations

/// Emitted when a stream is created
public struct StreamCreated has copy, drop {
    account_id: ID,
    stream_id: ID,
    cap_id: ID,
    beneficiary: address,
    total_amount: u64,
    coin_type: TypeName,
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
}

/// Emitted when funds are collected from a stream
public struct StreamCollected has copy, drop {
    account_id: ID,
    stream_id: ID,
    amount: u64,
    remaining_vested: u64,
    resource_name: String,
}

/// Emitted when a stream is cancelled
public struct StreamCancelled has copy, drop {
    account_id: ID,
    stream_id: ID,
    refunded_amount: u64,
    final_payment: u64,
}

/// Emitted when a spending limit is created
public struct SpendingLimitCreated has copy, drop {
    account_id: ID,
    spending_limit_id: ID,
    cap_id: ID,
    delegate: address,
    vault_name: String,
    coin_type: TypeName,
    amount_per_iteration: u64,
    iteration_period_ms: u64,
    iterations_total: u64,
    start_time: u64,
    whitelisted_recipients: vector<address>,
}

/// Emitted when funds are spent via spending limit
public struct SpendingLimitSpent has copy, drop {
    account_id: ID,
    spending_limit_id: ID,
    recipient: address,
    coin_type: TypeName,
    amount: u64,
    remaining_budget: u64,
}

/// Emitted when an expired spending limit is permissionlessly cleaned up
public struct SpendingLimitExpiredCleanup has copy, drop {
    account_id: ID,
    spending_limit_id: ID,
    expiry_ms: u64,
    cleaned_up_at: u64,
}

// === Public Functions ===

/// Permissionless deposit into a vault.
/// Non-donations vaults require the coin type to be approved by governance.
/// Vaults whose names start with "donations" accept any nonzero coin type.
public fun deposit_approved<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    name: String,
    coin: Coin<CoinType>,
) {
    // Validate non-zero deposit to prevent state spam
    assert!(coin.value() > 0, EAmountMustBeGreaterThanZero);

    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(name),
        version::current(),
    );

    let type_key = type_name::with_original_ids<CoinType>();
    let amount = coin.value();
    assert_coin_type_approved_for_deposit<CoinType>(vault, &name);

    // Add to existing balance or create new one
    if (vault.coin_type_exists<CoinType>()) {
        let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    } else {
        vault.bag.add(type_key, coin.into_balance());
    };

    event::emit(VaultDeposited {
        account_id: object::id(account),
        vault_name: name,
        coin_type: type_key,
        amount,
    });
}

/// Cap-gated withdrawal from a vault.
/// The VaultAdminCap must match the account and vault. Any registered package
/// holding a reference to the cap can withdraw — this is intentional: the cap
/// is the authorization token, not the caller's package identity.
public fun withdraw_with_admin_cap<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: &VaultAdminCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert!(cap.account_id == object::id(account), EAdminCapAccountMismatch);
    assert!(amount > 0, EAmountMustBeGreaterThanZero);

    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(cap.vault_name),
        version::current(),
    );

    let type_key = type_name::with_original_ids<CoinType>();
    assert!(vault.bag.contains(type_key), ECoinTypeDoesNotExist);

    let balance_mut: &mut Balance<CoinType> = vault.bag.borrow_mut(type_key);
    assert!(balance_mut.value() >= amount, EInsufficientBalance);

    let coin = coin::take(balance_mut, amount, ctx);

    if (balance_mut.value() == 0) {
        vault.bag.remove<_, Balance<CoinType>>(type_key).destroy_zero();
    };

    event::emit(VaultSpent {
        account_id: object::id(account),
        vault_name: cap.vault_name,
        coin_type: type_key,
        amount,
        resource_name: std::string::utf8(b"admin_cap_withdrawal"),
    });

    coin
}

/// Get the vault name from a VaultAdminCap.
public fun admin_cap_vault_name(cap: &VaultAdminCap): String {
    cap.vault_name
}

/// Get the account ID from a VaultAdminCap.
public fun admin_cap_account_id(cap: &VaultAdminCap): ID {
    cap.account_id
}

/// Destroy a VaultAdminCap (e.g. when cancelling a protective bid).
public fun destroy_vault_admin_cap(cap: VaultAdminCap) {
    let VaultAdminCap { id, vault_name: _, account_id: _ } = cap;
    object::delete(id);
}

/// Returns the balance of a specific coin type in a vault.
/// Convenience function that combines vault existence check with balance lookup.
public fun balance<Config: store, CoinType>(
    account: &Account,
    registry: &PackageRegistry,
    name: String,
): u64 {
    if (!has_vault(account, name)) {
        return 0
    };

    let vault: &Vault = account.borrow_managed_data_with_package_witness(registry, VaultKey(name), version::current());

    if (!coin_type_exists<CoinType>(vault)) {
        return 0
    };

    coin_type_value<CoinType>(vault)
}

/// Default vault name for standard operations
public fun default_vault_name(): String {
    std::string::utf8(b"Main Vault")
}

/// Returns true if the vault exists.
public fun has_vault(account: &Account, name: String): bool {
    account.has_managed_data(VaultKey(name))
}

/// Returns a reference to the vault.
public fun borrow_vault(account: &Account, registry: &PackageRegistry, name: String): &Vault {
    account.borrow_managed_data_with_package_witness(registry, VaultKey(name), version::current())
}

/// Returns true when a vault name should accept unapproved coin types.
/// The donations inbox convention is intentionally narrow:
///   - exact match `donations` (length == 9)
///   - or `donations_<suffix>` (e.g. `donations_usdc`)
///   - or `donations-<suffix>` (e.g. `donations-treasury`)
/// Anything else (`donationsXyz`, `Donations`, `DONATIONS`) returns false so a
/// typo cannot accidentally bypass the deposit allowlist.
public fun is_donations_vault_name(name: &String): bool {
    let bytes = std::string::as_bytes(name);
    let len = bytes.length();
    let prefix = b"donations";
    let prefix_len = prefix.length(); // 9

    // Must at least cover the bare word.
    if (len < prefix_len) {
        return false
    };

    // The first 9 bytes must literally be "donations" (case-sensitive).
    let mut i = 0;
    while (i < prefix_len) {
        if (*bytes.borrow(i) != *prefix.borrow(i)) {
            return false
        };
        i = i + 1;
    };

    // Exactly the bare word -> donations vault.
    if (len == prefix_len) {
        return true
    };

    // Otherwise we require `donations_<suffix>` or `donations-<suffix>` with a
    // non-empty suffix. This rejects `donationsrugpull` (no separator) and
    // bare `donations_` (empty suffix).
    if (len <= prefix_len + 1) {
        return false
    };
    let sep = *bytes.borrow(prefix_len);
    sep == 0x5fu8 || sep == 0x2du8
}

/// Returns the number of coin types in the vault.
public fun size(vault: &Vault): u64 {
    vault.bag.length()
}

/// Returns true if the coin type is approved for deposits into the vault.
public fun is_coin_type_approved<CoinType>(vault: &Vault): bool {
    vector::contains(&vault.approved_types, &type_name::with_original_ids<CoinType>())
}

/// Returns true if a coin type can be deposited into a named vault.
/// donations* vaults intentionally bypass the approval list.
public fun can_deposit_coin_type<CoinType>(vault: &Vault, name: &String): bool {
    is_donations_vault_name(name) || is_coin_type_approved<CoinType>(vault)
}

/// Returns the vault's approved deposit coin types.
public fun approved_coin_types(vault: &Vault): vector<TypeName> {
    vault.approved_types
}

fun default_approved_types(): vector<TypeName> {
    vector[type_name::with_original_ids<SUI>()]
}

fun assert_coin_type_approved_for_deposit<CoinType>(vault: &Vault, name: &String) {
    assert!(can_deposit_coin_type<CoinType>(vault, name), ECoinTypeNotApproved);
}

fun approve_coin_type_internal<CoinType>(vault: &mut Vault): TypeName {
    let type_key = type_name::with_original_ids<CoinType>();
    if (!vector::contains(&vault.approved_types, &type_key)) {
        vault.approved_types.push_back(type_key);
    };
    type_key
}

fun remove_approved_coin_type_internal<CoinType>(vault: &mut Vault): TypeName {
    let type_key = type_name::with_original_ids<CoinType>();
    let (found, idx) = vector::index_of(&vault.approved_types, &type_key);
    if (found) {
        vault.approved_types.remove(idx);
    };
    type_key
}

/// Returns true if the coin type exists in the vault.
public fun coin_type_exists<CoinType>(vault: &Vault): bool {
    vault.bag.contains(type_name::with_original_ids<CoinType>())
}

/// Returns the value of the coin type in the vault.
public fun coin_type_value<CoinType>(vault: &Vault): u64 {
    vault.bag.borrow<TypeName, Balance<CoinType>>(type_name::with_original_ids<CoinType>()).value()
}

/// Returns the maximum number of vaults allowed per account.
public fun max_vaults(): u64 {
    actions_constants::max_vaults()
}

/// Returns the number of vaults for this account.
public fun vault_count(account: &Account, registry: &PackageRegistry): u64 {
    if (!account.has_managed_data(VaultNamesKey {})) {
        return 0
    };
    let vault_names: &vector<String> = account.borrow_managed_data_with_package_witness(
        registry,
        VaultNamesKey {},
        version::current(),
    );
    vector::length(vault_names)
}

/// Returns the list of vault names for this account.
/// Returns empty vector if no vaults exist.
public fun vault_names(account: &Account, registry: &PackageRegistry): vector<String> {
    if (!account.has_managed_data(VaultNamesKey {})) {
        return vector::empty()
    };
    let vault_names: &vector<String> = account.borrow_managed_data_with_package_witness(
        registry,
        VaultNamesKey {},
        version::current(),
    );
    *vault_names
}

/// Get total balance of a coin type across ALL vaults for this account.
/// Streams share vault balances and are not reserved, so this reflects the raw balance.
/// Useful for NAV calculations that need aggregate treasury holdings.
public fun get_total_balance<Config: store, CoinType>(
    account: &Account,
    registry: &PackageRegistry,
): u64 {
    if (!account.has_managed_data(VaultNamesKey {})) {
        return 0
    };

    let names: &vector<String> = account.borrow_managed_data_with_package_witness(
        registry,
        VaultNamesKey {},
        version::current(),
    );

    let mut total: u64 = 0;
    let len = vector::length(names);
    let mut i = 0;
    let coin_type = type_name::with_original_ids<CoinType>();

    while (i < len) {
        let vault_name = vector::borrow(names, i);

        if (has_vault(account, *vault_name)) {
            let vault: &Vault = account.borrow_managed_data_with_package_witness(
                registry,
                VaultKey(*vault_name),
                version::current(),
            );

            if (vault.bag.contains(coin_type)) {
                let bal = vault.bag.borrow<TypeName, Balance<CoinType>>(coin_type).value();
                assert!(total <= u64::max_value!() - bal, EArithmeticOverflow);
                total = total + bal;
            };
        };

        i = i + 1;
    };

    total
}

// === Intent functions ===

/// Approve a coin type for deposits into a vault.
public fun do_approve_coin_type<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultApproveCoinType<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    let account_id = object::id(account);
    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );
    let coin_type = approve_coin_type_internal<CoinType>(vault);

    event::emit(CoinTypeApproved {
        account_id,
        vault_name,
        coin_type,
    });

    executable::increment_action_idx<_, VaultApproveCoinType<CoinType>, _>(
        executable,
        registry,
        ExecutionProgressWitness {},
    );
}

/// Remove a coin type approval from a vault.
public fun do_remove_approved_coin_type<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultRemoveApprovedCoinType<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    let account_id = object::id(account);
    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );
    let coin_type = remove_approved_coin_type_internal<CoinType>(vault);

    event::emit(CoinTypeApprovalRemoved {
        account_id,
        vault_name,
        coin_type,
    });

    executable::increment_action_idx<_, VaultRemoveApprovedCoinType<CoinType>, _>(
        executable,
        registry,
        ExecutionProgressWitness {},
    );
}

/// Processes a DepositAction and deposits a coin to the vault.
/// DETERMINISTIC: Takes coin from executable_resources (from previous action), NOT from PTB!
/// The resource_name in ActionSpec tells us which resource to take.
public fun do_init_deposit<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultDeposit<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct directly
    // ActionSpec contains: vault_name, amount, resource_name (where to take coin from)
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Take coin from executable_resources (deterministic - from previous action!)
    let coin: Coin<CoinType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    // Validate amount matches what was staged
    assert!(amount == coin.value(), EIntentAmountMismatch);

    // Capture account_id before mutable borrow
    let account_id = object::id(account);

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(name),
        executable,
        ExecutionProgressWitness {},
    );
    let type_key = type_name::with_original_ids<CoinType>();
    assert_coin_type_approved_for_deposit<CoinType>(vault, &name);

    if (!vault.coin_type_exists<CoinType>()) {
        vault.bag.add(type_key, coin.into_balance());
    } else {
        let balance_mut = vault
            .bag
            .borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    };

    event::emit(VaultDeposited {
        account_id,
        vault_name: name,
        coin_type: type_key,
        amount,
    });

    // Increment action index
    executable::increment_action_idx<_, VaultDeposit<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Deposit external coins from PTB into vault
/// SECURITY: Amount MUST match expected_amount (always validated, no exceptions)
/// For deposits where amount is unknown at staging time, use DepositFromResources
/// which takes coins from executable_resources (put there by a prior action)
public fun do_deposit_external<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    coin: Coin<CoinType>, // External coin from PTB
    _intent_witness: IW,
) {
    // 1. Assert account ownership
    executable.intent().assert_is_account(account.addr());

    // 2. Get current ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultDepositExternal<CoinType>>(action_spec);

    // 4. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 5. Deserialize action data
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let expected_amount = bcs::peel_u64(&mut reader);

    // 6. Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // 7. Get deposit amount and validate
    let actual_amount = coin.value();
    assert!(actual_amount == expected_amount, EIntentAmountMismatch);

    // 8. Perform deposit
    let account_id = object::id(account);

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(name),
        executable,
        ExecutionProgressWitness {},
    );

    let type_key = type_name::with_original_ids<CoinType>();
    assert_coin_type_approved_for_deposit<CoinType>(vault, &name);

    // Add to existing balance or create new
    if (!vault.coin_type_exists<CoinType>()) {
        vault.bag.add(type_key, coin.into_balance());
    } else {
        let balance_mut = vault
            .bag
            .borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    };

    event::emit(VaultDeposited {
        account_id,
        vault_name: name,
        coin_type: type_key,
        amount: actual_amount,
    });

    // 9. Increment action index
    executable::increment_action_idx<_, VaultDepositExternal<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Deposit coins from executable_resources into a vault
///
/// Takes coin from executable_resources (put there by a previous action like swap/LP)
/// and deposits to the specified vault.
///
/// SECURITY: This is safe because:
/// 1. Coins come from executable_resources (from prior governance-approved actions)
/// 2. Amount deposited = exactly what prior action produced (deterministic)
/// 3. Only proposal execution flow can call this
public fun do_init_deposit_from_resources<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    // 1. Assert account ownership
    executable.intent().assert_is_account(account.addr());

    // 2. Get current ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultDepositFromResources<CoinType>>(action_spec);

    // 4. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 5. Deserialize action data (vault_name and resource_name)
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // 6. Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // 7. Take coin from executable_resources (deterministic - put there by previous action)
    let coin: Coin<CoinType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    // 8. Perform deposit to specified vault
    let account_id = object::id(account);
    let amount = coin.value();

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );

    let type_key = type_name::with_original_ids<CoinType>();
    assert_coin_type_approved_for_deposit<CoinType>(vault, &vault_name);

    // Add to existing balance or create new
    if (!vault.coin_type_exists<CoinType>()) {
        vault.bag.add(type_key, coin.into_balance());
    } else {
        let balance_mut = vault
            .bag
            .borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    };

    event::emit(VaultDeposited {
        account_id,
        vault_name,
        coin_type: type_key,
        amount,
    });

    // 9. Increment action index
    executable::increment_action_idx<_, VaultDepositFromResources<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Deposit a Coin object from executable_resources into vault using take_object.
/// This handles coins stored via WithdrawObjectAction's provide_object (object_key format).
/// Use this for TTO coin recovery: WithdrawObject<Coin<T>> → VaultDepositObjectFromResources<T>
public fun do_init_deposit_object_from_resources<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultDepositObjectFromResources<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    // Take coin as object (matches object_key format from provide_object)
    let coin: Coin<CoinType> = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    let account_id = object::id(account);
    let amount = coin.value();

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );

    let type_key = type_name::with_original_ids<CoinType>();
    assert_coin_type_approved_for_deposit<CoinType>(vault, &vault_name);

    if (!vault.coin_type_exists<CoinType>()) {
        vault.bag.add(type_key, coin.into_balance());
    } else {
        let balance_mut = vault
            .bag
            .borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    };

    event::emit(VaultDeposited {
        account_id,
        vault_name,
        coin_type: type_key,
        amount,
    });

    executable::increment_action_idx<_, VaultDepositObjectFromResources<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

// === Execution Functions ===

/// Execute cancel stream action.
/// Governance-only operation: removes stream metadata but does not move funds.
/// NOTE: Any vested-but-unclaimed amounts are forfeited. Beneficiaries should claim
/// their vested portion before governance cancels the stream. The forfeited amount
/// is emitted in the StreamCancelled event for transparency.
public fun do_cancel_stream<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    _witness: IW,
    _ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CancelStream<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let stream_id = bcs::peel_address(&mut reader).to_id();

    bcs_validation::validate_all_bytes_consumed(reader);

    let account_id = object::id(account);

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(vault.streams.contains(stream_id), EStreamNotFound);

    let stream = table::remove(&mut vault.streams, stream_id);

    // Validate CoinType matches the stream's actual coin type to prevent spoofing
    // (proposer could encode a different stream_id in BCS than what CoinType suggests)
    assert!(stream.coin_type == type_name::with_original_ids<CoinType>(), EWrongCoinType);

    // Calculate forfeited vested amount for event transparency
    let current_time = clock.timestamp_ms();
    let forfeited_vested = if (current_time >= stream.start_time) {
        let (available, _, _) =
            stream_utils::calculate_available_with_tracking(
                stream.amount_per_iteration,
                stream.first_unclaimed_iteration,
                stream.partial_claimed_in_iteration,
                stream.start_time,
                stream.iterations_total,
                stream.iteration_period_ms,
                current_time,
                &stream.claim_window_ms,
            );
        available
    } else {
        0
    };

    event::emit(StreamCancelled {
        account_id,
        stream_id,
        refunded_amount: 0,
        final_payment: forfeited_vested,
    });

    executable::increment_action_idx<_, CancelStream<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Processes a SpendAction and takes a coin from the vault.
/// If spend_all is true, withdraws entire balance regardless of amount field.
/// The coin is provided to executable_resources under the given resource_name
/// for consumption by subsequent actions (e.g., TransferObject, Deposit).
public fun do_spend<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultSpend<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize the entire action struct directly
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);
    let spend_all = bcs::peel_bool(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Capture account_id before mutable borrow
    let account_id = object::id(account);

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(name),
        executable,
        ExecutionProgressWitness {},
    );
    let type_key = type_name::with_original_ids<CoinType>();
    let coin = if (!vault.bag.contains(type_key)) {
        assert!(spend_all, ECoinTypeDoesNotExist);
        coin::zero<CoinType>(ctx)
    } else {
        let balance_mut: &mut Balance<CoinType> = vault
            .bag
            .borrow_mut<_, Balance<CoinType>>(type_key);

        // Determine actual amount to withdraw
        let withdraw_amount = if (spend_all) {
            balance_mut.value() // Spend entire balance
        } else {
            amount // Spend specified amount
        };

        let coin = coin::take(balance_mut, withdraw_amount, ctx);

        if (balance_mut.value() == 0) {
            vault
                .bag
                .remove<_, Balance<CoinType>>(type_key)
                .destroy_zero();
        };

        coin
    };
    let withdraw_amount = coin.value();

    event::emit(VaultSpent {
        account_id,
        vault_name: name,
        coin_type: type_key,
        amount: withdraw_amount,
        resource_name,
    });

    // Provide coin to executable_resources for subsequent actions
    // Use provide_coin so take_coin can retrieve it (compatible with do_init_transfer_coin)
    executable_resources::provide_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        coin,
        ctx,
    );

    // Increment action index
    executable::increment_action_idx<_, VaultSpend<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

// === Stream Management Functions ===

/// Collect vested tokens from a stream via governance action.
/// StreamCap must be in executable_resources under cap_resource_name
/// (via ProvideObjectToResources or OwnedWithdrawObject).
/// The cap is returned to executable_resources after use so subsequent actions
/// can handle it (e.g., TransferObject to return it to the holder).
/// Collected coins go to executable_resources under resource_name.
/// ActionSpec data: vault_name (String), stream_id (address), resource_name (String),
///   amount (u64), cap_resource_name (String)
public fun do_collect_stream<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CollectStream<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);

    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let stream_id = bcs::peel_address(&mut reader).to_id();
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let amount = bcs::peel_u64(&mut reader);
    let cap_resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    // Take StreamCap from executable_resources
    let cap: StreamCap = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        cap_resource_name,
    );

    let account_id = object::id(account);
    // Validate StreamCap binding to stream + account + vault.
    assert!(cap.stream_id == stream_id, EStreamCapMismatch);
    assert!(cap.account_id == account_id, EStreamCapMismatch);
    assert!(cap.account_addr == account.addr(), EStreamCapMismatch);
    assert!(cap.vault_name == vault_name, EStreamCapMismatch);

    let vault: &mut Vault = account.borrow_managed_data_mut(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::borrow_mut(&mut vault.streams, stream_id);
    let stream_coin_type = stream.coin_type;
    let iterations_total = stream.iterations_total;
    let current_time = clock.timestamp_ms();

    // Check if stream has started
    assert!(current_time >= stream.start_time, EStreamNotStarted);

    // Calculate available using precise iteration tracking
    let (available, adj_first, adj_partial) =
        account_actions::stream_utils::calculate_available_with_tracking(
            stream.amount_per_iteration,
            stream.first_unclaimed_iteration,
            stream.partial_claimed_in_iteration,
            stream.start_time,
            stream.iterations_total,
            stream.iteration_period_ms,
            current_time,
            &stream.claim_window_ms,
        );

    // Determine actual claim amount (0 = claim all available)
    let claim_amount = if (amount == 0) { available } else { amount };

    assert!(available >= claim_amount, EInsufficientVestedAmount);

    // Update tracking state
    let (new_first, new_partial) = account_actions::stream_utils::advance_claim_tracking(
        adj_first,
        adj_partial,
        claim_amount,
        stream.amount_per_iteration,
    );
    stream.first_unclaimed_iteration = new_first;
    stream.partial_claimed_in_iteration = new_partial;
    stream.claimed_amount = stream.claimed_amount + claim_amount;

    // Retire fully-claimed stream so StreamCap can be destroyed and vault can be closed
    let stream_fully_claimed = new_first >= iterations_total;

    // Verify coin type still exists in vault
    assert!(vault.bag.contains(stream_coin_type), EInsufficientBalance);

    // Withdraw from vault balance
    let balance_mut = vault.bag.borrow_mut<TypeName, Balance<CoinType>>(stream_coin_type);
    let coin = coin::take(balance_mut, claim_amount, ctx);

    event::emit(StreamCollected {
        account_id,
        stream_id,
        amount: claim_amount,
        remaining_vested: available - claim_amount,
        resource_name,
    });

    // Clean up empty balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<TypeName, Balance<CoinType>>(stream_coin_type).destroy_zero();
    };

    // Remove completed stream from vault (M-4 fix)
    if (stream_fully_claimed) {
        table::remove(&mut vault.streams, stream_id);
    };

    // Provide coin to executable_resources for subsequent actions
    executable_resources::provide_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        coin,
        ctx,
    );

    // Return StreamCap to executable_resources for subsequent actions
    // (e.g., TransferObject to return it to the cap holder)
    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        cap_resource_name,
        cap,
        ctx,
    );

    executable::increment_action_idx<_, CollectStream<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Permissionless stream collection for StreamCap holders.
/// The beneficiary can claim vested tokens without a governance proposal.
/// StreamCap ownership is enforced by Sui's object model.
/// Returns claimed coins directly to the caller.
public fun collect_stream<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: &StreamCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    let account_id = object::id(account);
    // Validate StreamCap binding to stream + account + vault.
    assert!(cap.account_id == account_id, EStreamCapMismatch);
    assert!(cap.account_addr == account.addr(), EStreamCapMismatch);

    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(cap.vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, cap.stream_id), EStreamNotFound);

    let stream = table::borrow_mut(&mut vault.streams, cap.stream_id);
    let stream_coin_type = stream.coin_type;
    let iterations_total = stream.iterations_total;
    let current_time = clock.timestamp_ms();

    // Check if stream has started
    assert!(current_time >= stream.start_time, EStreamNotStarted);

    // Calculate available using precise iteration tracking
    let (available, adj_first, adj_partial) =
        account_actions::stream_utils::calculate_available_with_tracking(
            stream.amount_per_iteration,
            stream.first_unclaimed_iteration,
            stream.partial_claimed_in_iteration,
            stream.start_time,
            stream.iterations_total,
            stream.iteration_period_ms,
            current_time,
            &stream.claim_window_ms,
        );

    // Determine actual claim amount (0 = claim all available)
    let claim_amount = if (amount == 0) { available } else { amount };

    assert!(available >= claim_amount, EInsufficientVestedAmount);

    // Update tracking state
    let (new_first, new_partial) = account_actions::stream_utils::advance_claim_tracking(
        adj_first,
        adj_partial,
        claim_amount,
        stream.amount_per_iteration,
    );
    stream.first_unclaimed_iteration = new_first;
    stream.partial_claimed_in_iteration = new_partial;
    stream.claimed_amount = stream.claimed_amount + claim_amount;

    // Retire fully-claimed stream so StreamCap can be destroyed and vault can be closed
    let stream_fully_claimed = new_first >= iterations_total;

    // Verify coin type still exists in vault
    assert!(vault.bag.contains(stream_coin_type), EInsufficientBalance);

    // Withdraw from vault balance
    let balance_mut = vault.bag.borrow_mut<TypeName, Balance<CoinType>>(stream_coin_type);
    let coin = coin::take(balance_mut, claim_amount, ctx);

    event::emit(StreamCollected {
        account_id,
        stream_id: cap.stream_id,
        amount: claim_amount,
        remaining_vested: available - claim_amount,
        resource_name: std::string::utf8(b""),
    });

    // Clean up empty balance if needed
    if (balance_mut.value() == 0) {
        vault.bag.remove<TypeName, Balance<CoinType>>(stream_coin_type).destroy_zero();
    };

    // Remove completed stream from vault (M-4 fix)
    if (stream_fully_claimed) {
        table::remove(&mut vault.streams, cap.stream_id);
    };

    coin
}

/// Permissionless spending for SpendingCap holders.
/// The delegate can spend vested budget to any whitelisted recipient.
/// Funds are transferred directly to the recipient (delegate cannot intercept).
/// SpendingCap ownership is enforced by Sui's object model.
public fun spend_with_cap<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: &SpendingCap,
    recipient: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let account_id = object::id(account);
    assert!(cap.account_id == account_id, ESpendingCapMismatch);
    assert!(cap.account_addr == account.addr(), ESpendingCapMismatch);
    assert!(amount > 0, EAmountMustBeGreaterThanZero);

    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(cap.vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, cap.spending_limit_id), ESpendingLimitNotFound);

    let stream = table::borrow_mut(&mut vault.streams, cap.spending_limit_id);

    // Validate recipient is whitelisted
    assert!(vector::contains(&stream.whitelisted_recipients, &recipient), ERecipientNotWhitelisted);

    let current_time = clock.timestamp_ms();

    // Check hard expiry
    if (stream.expiry_ms.is_some()) {
        assert!(current_time < *stream.expiry_ms.borrow(), ESpendingLimitExpired);
    };

    // Check started
    assert!(current_time >= stream.start_time, ESpendingLimitNotStarted);

    // Calculate available budget using stream_utils
    let (available, adj_first, adj_partial) =
        stream_utils::calculate_available_with_tracking(
            stream.amount_per_iteration,
            stream.first_unclaimed_iteration,
            stream.partial_claimed_in_iteration,
            stream.start_time,
            stream.iterations_total,
            stream.iteration_period_ms,
            current_time,
            &stream.claim_window_ms,
        );

    assert!(available >= amount, EInsufficientSpendingBudget);

    // Update tracking state
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        adj_first,
        adj_partial,
        amount,
        stream.amount_per_iteration,
    );
    stream.first_unclaimed_iteration = new_first;
    stream.partial_claimed_in_iteration = new_partial;
    stream.claimed_amount = stream.claimed_amount + amount;

    let spending_limit_id = stream.id;
    let stream_coin_type = stream.coin_type;
    let iterations_total = stream.iterations_total;

    // Auto-remove fully consumed spending limit
    let fully_consumed = new_first >= iterations_total;

    // Withdraw from vault balance
    assert!(vault.bag.contains(stream_coin_type), EInsufficientBalance);
    let balance_mut = vault.bag.borrow_mut<TypeName, Balance<CoinType>>(stream_coin_type);
    assert!(balance_mut.value() >= amount, EInsufficientBalance);
    let coin = coin::take(balance_mut, amount, ctx);

    if (balance_mut.value() == 0) {
        vault.bag.remove<TypeName, Balance<CoinType>>(stream_coin_type).destroy_zero();
    };

    if (fully_consumed) {
        table::remove(&mut vault.streams, spending_limit_id);
    };

    event::emit(SpendingLimitSpent {
        account_id,
        spending_limit_id,
        recipient,
        coin_type: stream_coin_type,
        amount,
        remaining_budget: available - amount,
    });

    // Transfer directly to recipient (delegate cannot intercept)
    transfer::public_transfer(coin, recipient);
}

fun validate_spending_limit_recipients(whitelisted_recipients: &vector<address>) {
    let len = whitelisted_recipients.length();
    assert!(len > 0, EEmptyWhitelist);
    assert!(len <= actions_constants::max_beneficiaries(), ETooManyRecipients);

    let mut i = 0;
    while (i < len) {
        let recipient = *whitelisted_recipients.borrow(i);
        assert!(recipient != @0x0, EZeroWhitelistRecipient);

        let mut j = i + 1;
        while (j < len) {
            assert!(recipient != *whitelisted_recipients.borrow(j), EDuplicateWhitelistRecipient);
            j = j + 1;
        };
        i = i + 1;
    };
}

/// Calculate how much can be claimed from a stream
public fun calculate_claimable<Config: store>(
    account: &Account,
    registry: &PackageRegistry,
    vault_name: String,
    stream_id: ID,
    clock: &Clock,
): u64 {
    let vault: &Vault = account.borrow_managed_data_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();

    let (available, _, _) = account_actions::stream_utils::calculate_available_with_tracking(
        stream.amount_per_iteration,
        stream.first_unclaimed_iteration,
        stream.partial_claimed_in_iteration,
        stream.start_time,
        stream.iterations_total,
        stream.iteration_period_ms,
        current_time,
        &stream.claim_window_ms,
    );
    available
}

/// Get stream information
/// Returns: (amount_per_iteration, claimed_amount, start_time, iterations_total, iteration_period_ms)
/// Note: All streams are always cancellable by DAO governance
public fun stream_info<Config: store>(
    account: &Account,
    registry: &PackageRegistry,
    vault_name: String,
    stream_id: ID,
): (u64, u64, u64, u64, u64) {
    let vault: &Vault = account.borrow_managed_data_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, stream_id), EStreamNotFound);

    let stream = table::borrow(&vault.streams, stream_id);
    (
        stream.amount_per_iteration,
        stream.claimed_amount,
        stream.start_time,
        stream.iterations_total,
        stream.iteration_period_ms,
    )
}

/// Check if a stream exists
public fun has_stream(
    account: &Account,
    registry: &PackageRegistry,
    vault_name: String,
    stream_id: ID,
): bool {
    if (!account.has_managed_data(VaultKey(vault_name))) {
        return false
    };

    let vault: &Vault = account.borrow_managed_data_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    table::contains(&vault.streams, stream_id)
}

/// StreamCap accessor: stream ID
public fun stream_cap_stream_id(cap: &StreamCap): ID { cap.stream_id }

/// StreamCap accessor: account ID
public fun stream_cap_account_id(cap: &StreamCap): ID { cap.account_id }

/// StreamCap accessor: account address
public fun stream_cap_account_addr(cap: &StreamCap): address { cap.account_addr }

/// StreamCap accessor: vault name
public fun stream_cap_vault_name(cap: &StreamCap): String { cap.vault_name }

/// Destroy a StreamCap whose stream has been cancelled or fully claimed.
/// Permissionless: the caller must own the StreamCap (enforced by Sui's object model).
/// Aborts if the stream still exists in the vault (prevents premature destruction).
/// If the vault itself has been closed, the stream is guaranteed gone — safe to delete.
public fun destroy_stream_cap(
    cap: StreamCap,
    account: &Account,
    registry: &PackageRegistry,
) {
    let StreamCap { id, stream_id, account_id, account_addr: _, vault_name } = cap;
    assert!(account_id == object::id(account), EStreamCapMismatch);
    // If vault still exists, verify the stream has been removed (cancelled or fully claimed).
    // If vault has been closed (deleted), the stream is guaranteed gone.
    if (account.has_managed_data(VaultKey(vault_name))) {
        let vault: &Vault = account::borrow_managed_data_with_package_witness(
            account,
            registry,
            VaultKey(vault_name),
            version::current(),
        );
        assert!(!table::contains(&vault.streams, stream_id), EStreamStillActive);
    };
    object::delete(id);
}

// === SpendingCap Accessors ===

/// SpendingCap accessor: spending limit ID
public fun spending_cap_spending_limit_id(cap: &SpendingCap): ID { cap.spending_limit_id }

/// SpendingCap accessor: account ID
public fun spending_cap_account_id(cap: &SpendingCap): ID { cap.account_id }

/// SpendingCap accessor: account address
public fun spending_cap_account_addr(cap: &SpendingCap): address { cap.account_addr }

/// SpendingCap accessor: vault name
public fun spending_cap_vault_name(cap: &SpendingCap): String { cap.vault_name }

/// Permissionless cleanup of an expired spending limit.
/// `spend_with_cap` aborts on expiry without auto-removing the entry, leaving
/// the SpendingCap permanently undeletable. Anyone may call this to clear an
/// expired entry from the vault so the holder can later destroy their cap.
/// Aborts if the limit has no hard expiry or is not yet past its expiry.
public fun cleanup_expired_spending_limit<Config: store>(
    account: &mut Account,
    registry: &PackageRegistry,
    vault_name: String,
    spending_limit_id: ID,
    clock: &Clock,
) {
    let account_id = object::id(account);
    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, spending_limit_id), ESpendingLimitNotFound);

    let stream = table::borrow(&vault.streams, spending_limit_id);
    assert!(stream.expiry_ms.is_some(), ESpendingLimitNoExpiry);
    let expiry = *stream.expiry_ms.borrow();
    let current_time = clock.timestamp_ms();
    assert!(current_time >= expiry, ESpendingLimitNotExpired);

    table::remove(&mut vault.streams, spending_limit_id);

    event::emit(SpendingLimitExpiredCleanup {
        account_id,
        spending_limit_id,
        expiry_ms: expiry,
        cleaned_up_at: current_time,
    });
}

/// Destroy a SpendingCap whose spending limit has been cancelled/revoked or fully consumed.
/// Permissionless: the caller must own the SpendingCap (enforced by Sui's object model).
/// Aborts if the spending limit still exists in the vault.
public fun destroy_spending_cap(
    cap: SpendingCap,
    account: &Account,
    registry: &PackageRegistry,
) {
    let SpendingCap { id, spending_limit_id, account_id, account_addr: _, vault_name } = cap;
    assert!(account_id == object::id(account), ESpendingCapMismatch);
    if (account.has_managed_data(VaultKey(vault_name))) {
        let vault: &Vault = account::borrow_managed_data_with_package_witness(
            account,
            registry,
            VaultKey(vault_name),
            version::current(),
        );
        assert!(!table::contains(&vault.streams, spending_limit_id), ESpendingLimitStillActive);
    };
    object::delete(id);
}

/// Calculate available budget for a spending limit
public fun spending_limit_available<Config: store>(
    account: &Account,
    registry: &PackageRegistry,
    vault_name: String,
    spending_limit_id: ID,
    clock: &Clock,
): u64 {
    let vault: &Vault = account.borrow_managed_data_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, spending_limit_id), ESpendingLimitNotFound);

    let stream = table::borrow(&vault.streams, spending_limit_id);
    let current_time = clock.timestamp_ms();

    // Check expiry
    if (stream.expiry_ms.is_some() && current_time >= *stream.expiry_ms.borrow()) {
        return 0
    };

    if (current_time < stream.start_time) {
        return 0
    };

    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        stream.amount_per_iteration,
        stream.first_unclaimed_iteration,
        stream.partial_claimed_in_iteration,
        stream.start_time,
        stream.iterations_total,
        stream.iteration_period_ms,
        current_time,
        &stream.claim_window_ms,
    );
    available
}

/// Get spending limit whitelisted recipients
public fun spending_limit_recipients<Config: store>(
    account: &Account,
    registry: &PackageRegistry,
    vault_name: String,
    spending_limit_id: ID,
): vector<address> {
    let vault: &Vault = account.borrow_managed_data_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    assert!(table::contains(&vault.streams, spending_limit_id), ESpendingLimitNotFound);
    let stream = table::borrow(&vault.streams, spending_limit_id);
    stream.whitelisted_recipients
}

/// Create a stream - internal helper used by both init and proposal flows.
/// Directly creates a stream without requiring Auth (auth handled by caller).
/// All streams are cancellable by DAO governance (cancel & recreate to modify).
/// Mints StreamCap and transfers to beneficiary.
/// SECURITY: This is public(package) so only trusted code can call it.
/// For unshared accounts, caller has ownership-based auth.
/// For shared accounts, caller (do_init_create_stream) validates via intents.
public(package) fun create_stream_internal<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    vault_name: String,
    beneficiary: address,
    amount_per_iteration: u64,
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate stream parameters
    let current_time = clock.timestamp_ms();
    assert!(
        account_actions::stream_utils::validate_iteration_parameters(
            start_time,
            iterations_total,
            iteration_period_ms,
            &claim_window_ms,
            current_time,
        ),
        EInvalidStreamParameters,
    );
    assert!(amount_per_iteration > 0, EAmountMustBeGreaterThanZero);
    assert!(beneficiary != @0x0, EZeroBeneficiary);

    // Ensure vault exists and has sufficient balance
    let vault_exists = account.has_managed_data(VaultKey(vault_name));
    assert!(vault_exists, EVaultDoesNotExist);

    // Capture account_id and account_addr before mutable borrow
    let account_id = object::id(account);
    let account_addr = account.addr();

    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    let coin_type_name = type_name::with_original_ids<CoinType>();

    // Calculate total amount needed (with overflow protection)
    let total_amount_u128 = (amount_per_iteration as u128) * (iterations_total as u128);
    assert!(total_amount_u128 <= (u64::max_value!() as u128), EInsufficientBalance);
    let total_amount = (total_amount_u128 as u64);

    // No balance / coin-type assertion — vault is a shared pool and coins
    // (along with their bag entry) can be deposited later. The bag entry can
    // also be purged dynamically when a balance hits zero, so requiring it
    // here would block legitimate stream creation against an empty vault.

    // Create stream ID
    let stream_uid = object::new(ctx);
    let stream_id = object::uid_to_inner(&stream_uid);
    object::delete(stream_uid);

    // Create stream (always cancellable by DAO governance)
    let stream = VaultStream {
        id: stream_id,
        coin_type: coin_type_name,
        amount_per_iteration,
        claimed_amount: 0,
        first_unclaimed_iteration: 0,
        partial_claimed_in_iteration: 0,
        start_time,
        iterations_total,
        iteration_period_ms,
        claim_window_ms,
        whitelisted_recipients: vector::empty(),
        expiry_ms: option::none(),
    };

    // Copy ID before moving stream
    let stream_id_copy = stream.id;

    // Add stream to vault
    table::add(&mut vault.streams, stream_id_copy, stream);

    // Mint StreamCap and transfer to beneficiary
    let cap = StreamCap {
        id: object::new(ctx),
        stream_id: stream_id_copy,
        account_id,
        account_addr,
        vault_name,
    };
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, beneficiary);

    // Emit event
    event::emit(StreamCreated {
        account_id,
        stream_id: stream_id_copy,
        cap_id,
        beneficiary,
        total_amount,
        coin_type: coin_type_name,
        start_time,
        iterations_total,
        iteration_period_ms,
    });

    stream_id_copy
}

/// Execute create_stream from Intent.
/// Creates either a regular stream (StreamCap) or a spending limit (SpendingCap)
/// based on whether whitelisted_recipients is non-empty.
///
/// BCS format: vault_name (String), beneficiary/delegate (address),
///   amount_per_iteration (u64), start_time (Option<u64>),
///   iterations_total (u64), iteration_period_ms (u64),
///   claim_window_ms (Option<u64>), expiry_ms (Option<u64>),
///   whitelisted_recipients (vector<address>)
///
/// If whitelisted_recipients is empty → regular stream, mints StreamCap to beneficiary.
/// If whitelisted_recipients is non-empty → spending limit, mints SpendingCap to delegate.
public fun do_init_create_stream<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
): ID {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CreateStream<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let beneficiary = bcs::peel_address(&mut reader);
    let amount_per_iteration = bcs::peel_u64(&mut reader);

    let start_time_opt = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };

    let iterations_total = bcs::peel_u64(&mut reader);
    let iteration_period_ms = bcs::peel_u64(&mut reader);

    let claim_window_ms = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };

    // New optional fields
    let expiry_ms = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };

    let num_recipients = bcs::peel_vec_length(&mut reader);
    let mut whitelisted_recipients = vector::empty<address>();
    let mut i = 0;
    while (i < num_recipients) {
        whitelisted_recipients.push_back(bcs::peel_address(&mut reader));
        i = i + 1;
    };

    bcs_validation::validate_all_bytes_consumed(reader);

    if (whitelisted_recipients.is_empty()) {
        assert!(expiry_ms.is_none(), EExpiryNotSupportedForStream);
    } else {
        validate_spending_limit_recipients(&whitelisted_recipients);
    };

    let start_time = if (start_time_opt.is_some()) {
        *start_time_opt.borrow()
    } else {
        clock.timestamp_ms()
    };

    // If whitelist is non-empty → spending limit, else → regular stream
    let stream_id = if (!whitelisted_recipients.is_empty()) {
        create_spending_limit_internal<Config, CoinType>(
            account,
            registry,
            vault_name,
            beneficiary, // "beneficiary" is the delegate for spending limits
            amount_per_iteration,
            start_time,
            iterations_total,
            iteration_period_ms,
            claim_window_ms,
            expiry_ms,
            whitelisted_recipients,
            clock,
            ctx,
        )
    } else {
        create_stream_internal<Config, CoinType>(
            account,
            registry,
            vault_name,
            beneficiary,
            amount_per_iteration,
            start_time,
            iterations_total,
            iteration_period_ms,
            claim_window_ms,
            clock,
            ctx,
        )
    };

    executable::increment_action_idx<_, CreateStream<CoinType>, _>(executable, registry, ExecutionProgressWitness {});

    stream_id
}

/// Create a spending limit — internal helper.
/// Creates a VaultStream with whitelisted recipients and mints SpendingCap to delegate.
public(package) fun create_spending_limit_internal<Config: store, CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    vault_name: String,
    delegate: address,
    amount_per_iteration: u64,
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms: Option<u64>,
    expiry_ms: Option<u64>,
    whitelisted_recipients: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Validate parameters
    let current_time = clock.timestamp_ms();
    assert!(
        stream_utils::validate_iteration_parameters(
            start_time,
            iterations_total,
            iteration_period_ms,
            &claim_window_ms,
            current_time,
        ),
        EInvalidStreamParameters,
    );
    assert!(amount_per_iteration > 0, EAmountMustBeGreaterThanZero);
    assert!(delegate != @0x0, EZeroBeneficiary);
    validate_spending_limit_recipients(&whitelisted_recipients);

    // Validate expiry is in the future if set
    if (expiry_ms.is_some()) {
        let expiry = *expiry_ms.borrow();
        assert!(expiry > current_time, ESpendingLimitExpired);
        let first_unlock = (start_time as u128) + (iteration_period_ms as u128);
        assert!((expiry as u128) > first_unlock, ESpendingLimitExpired);
    };

    // Ensure vault exists and has the coin type
    assert!(account.has_managed_data(VaultKey(vault_name)), EVaultDoesNotExist);

    let account_id = object::id(account);
    let account_addr = account.addr();

    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry,
        VaultKey(vault_name),
        version::current(),
    );
    let coin_type_name = type_name::with_original_ids<CoinType>();
    // No balance / coin-type assertion — vault is a shared pool and coins can
    // be deposited later; balance only matters at spend_with_cap time.

    // Overflow check on total amount
    let total_amount_u128 = (amount_per_iteration as u128) * (iterations_total as u128);
    assert!(total_amount_u128 <= (u64::max_value!() as u128), EArithmeticOverflow);
    let _total_amount = (total_amount_u128 as u64);

    // Create spending limit ID
    let sl_uid = object::new(ctx);
    let sl_id = object::uid_to_inner(&sl_uid);
    object::delete(sl_uid);

    let stream = VaultStream {
        id: sl_id,
        coin_type: coin_type_name,
        amount_per_iteration,
        claimed_amount: 0,
        first_unclaimed_iteration: 0,
        partial_claimed_in_iteration: 0,
        start_time,
        iterations_total,
        iteration_period_ms,
        claim_window_ms,
        whitelisted_recipients,
        expiry_ms,
    };

    let sl_id_copy = stream.id;
    table::add(&mut vault.streams, sl_id_copy, stream);

    // Mint SpendingCap and transfer to delegate
    let cap = SpendingCap {
        id: object::new(ctx),
        spending_limit_id: sl_id_copy,
        account_id,
        account_addr,
        vault_name,
    };
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, delegate);

    event::emit(SpendingLimitCreated {
        account_id,
        spending_limit_id: sl_id_copy,
        cap_id,
        delegate,
        vault_name,
        coin_type: coin_type_name,
        amount_per_iteration,
        iteration_period_ms,
        iterations_total,
        start_time,
        whitelisted_recipients,
    });

    sl_id_copy
}

/// Execute open vault action via governance.
/// New vaults approve SUI deposits by default. Additional coin types must be
/// approved separately, except for donations* vaults.
public fun do_init_open<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultOpen>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize - just vault_name
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check vault doesn't already exist
    assert!(!account.has_managed_data(VaultKey(vault_name)), EVaultAlreadyExists);

    // Initialize vault names registry if it doesn't exist
    if (!account.has_managed_data(VaultNamesKey {})) {
        account.add_managed_data(
            registry,
            VaultNamesKey {},
            vector::empty<String>(),
            executable,
            ExecutionProgressWitness {},
        );
    };

    // Check vault limit
    let vault_names: &vector<String> = account.borrow_managed_data_with_package_witness(
        registry,
        VaultNamesKey {},
        version::current(),
    );
    assert!(vector::length(vault_names) < actions_constants::max_vaults(), ETooManyVaults);

    // Add vault name to registry
    let vault_names_mut: &mut vector<String> = account.borrow_managed_data_mut(
        registry,
        VaultNamesKey {},
        executable,
        ExecutionProgressWitness {},
    );
    vector::push_back(vault_names_mut, vault_name);

    // Create the vault
    let vault = Vault {
        bag: bag::new(ctx),
        approved_types: default_approved_types(),
        streams: table::new(ctx),
    };
    account.add_managed_data(
        registry,
        VaultKey(vault_name),
        vault,
        executable,
        ExecutionProgressWitness {},
    );

    // Emit event
    event::emit(VaultOpened {
        account_id: object::id(account),
        vault_name,
    });

    // Increment action index
    executable::increment_action_idx<_, VaultOpen, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute close vault action via governance
/// Removes an empty vault (must have no balances and no streams)
public fun do_init_close<Config: store, Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<VaultClose>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Deserialize - just vault_name
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Remove and destroy the vault
    let Vault { bag, approved_types: _, streams } = account.remove_managed_data(
        registry,
        VaultKey(vault_name),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(bag.is_empty(), EVaultNotEmpty);
    assert!(streams.is_empty(), EVaultNotEmpty);
    bag.destroy_empty();
    streams.destroy_empty();

    // Remove vault name from registry
    if (account.has_managed_data(VaultNamesKey {})) {
        let vault_names_mut: &mut vector<String> = account.borrow_managed_data_mut(
            registry,
            VaultNamesKey {},
            executable,
            ExecutionProgressWitness {},
        );
        let (found, idx) = vector::index_of(vault_names_mut, &vault_name);
        if (found) {
            vector::remove(vault_names_mut, idx);
        };
    };

    // Emit event
    event::emit(VaultClosed {
        account_id: object::id(account),
        vault_name,
    });

    // Increment action index
    executable::increment_action_idx<_, VaultClose, _>(executable, registry, ExecutionProgressWitness {});
}

/// Mint a VaultAdminCap for a specific vault and place it in executable_resources.
/// The next action (e.g. CreateProtectiveBid) can take it via executable_resources::take_object.
public fun do_mint_vault_admin_cap<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<MintVaultAdminCap>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let vault_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    // Validate the vault exists
    assert!(has_vault(account, vault_name), EVaultDoesNotExist);

    let cap = VaultAdminCap {
        id: object::new(ctx),
        vault_name,
        account_id: object::id(account),
    };

    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        cap,
        ctx,
    );

    executable::increment_action_idx<_, MintVaultAdminCap, _>(executable, registry, ExecutionProgressWitness {});
}

// === Preview Functions ===

/// Calculate currently claimable amount from a stream
public fun stream_claimable_now(vault: &Vault, stream_id: ID, clock: &Clock): u64 {
    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();

    if (current_time < stream.start_time) {
        return 0
    };

    // Calculate claimable using precise iteration tracking
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        stream.amount_per_iteration,
        stream.first_unclaimed_iteration,
        stream.partial_claimed_in_iteration,
        stream.start_time,
        stream.iterations_total,
        stream.iteration_period_ms,
        current_time,
        &stream.claim_window_ms,
    );
    available
}

/// Get next vesting time for an iteration-based stream
/// Returns the timestamp when the next iteration will unlock
public fun stream_next_vest_time(vault: &Vault, stream_id: ID, clock: &Clock): Option<u64> {
    let stream = table::borrow(&vault.streams, stream_id);
    let current_time = clock.timestamp_ms();

    // Before start: first unlock is at start_time + iteration_period_ms
    // (at start_time exactly, 0 iterations have completed so nothing is claimable)
    if (current_time < stream.start_time) {
        let first_unlock = (stream.start_time as u128) + (stream.iteration_period_ms as u128);
        if (first_unlock > (18446744073709551615u128)) {
            return option::none()
        };
        return option::some((first_unlock as u64))
    };

    // Calculate current iteration
    let elapsed = current_time - stream.start_time;
    let current_iteration = elapsed / stream.iteration_period_ms;

    // If all iterations complete, no more vesting
    if (current_iteration >= stream.iterations_total) {
        return option::none()
    };

    // Next iteration time (use u128 intermediate to prevent overflow)
    let next_time_u128 =
        (stream.start_time as u128) + (((current_iteration as u128) + 1) * (stream.iteration_period_ms as u128));
    if (next_time_u128 > (18446744073709551615u128)) {
        return option::none()
    };
    option::some((next_time_u128 as u64))
}

#[test_only]
public fun create_vault_admin_cap_for_testing(
    vault_name: String,
    account_id: ID,
    ctx: &mut TxContext,
): VaultAdminCap {
    VaultAdminCap {
        id: object::new(ctx),
        vault_name,
        account_id,
    }
}

#[test_only]
/// Open a vault on an Account directly, bypassing the Executable flow.
/// Also registers the vault name in VaultNamesKey so get_total_balance works.
public fun open_vault_for_testing(
    account: &mut Account,
    registry: &PackageRegistry,
    name: String,
    ctx: &mut TxContext,
) {
    let v = version::current_for_testing();

    // Initialize vault names registry if it doesn't exist
    if (!account.has_managed_data(VaultNamesKey {})) {
        account::add_managed_data_with_package_witness(
            account, registry, VaultNamesKey {}, vector::empty<String>(), v,
        );
    };

    // Register vault name
    let vault_names_mut: &mut vector<String> =
        account.borrow_managed_data_mut_with_package_witness(
            registry, VaultNamesKey {}, v,
        );
    vector::push_back(vault_names_mut, name);

    // Create the vault
    let vault = Vault {
        bag: sui::bag::new(ctx),
        approved_types: default_approved_types(),
        streams: sui::table::new(ctx),
    };
    account::add_managed_data_with_package_witness(
        account, registry, VaultKey(name), vault, v,
    );
}

#[test_only]
/// Deposit coins directly into a vault.
public fun deposit_for_testing<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    vault_name: String,
    coin: Coin<CoinType>,
) {
    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry, VaultKey(vault_name), version::current_for_testing(),
    );
    let type_key = type_name::with_original_ids<CoinType>();
    if (vault.bag.contains(type_key)) {
        let balance_mut = vault.bag.borrow_mut<_, Balance<_>>(type_key);
        balance_mut.join(coin.into_balance());
    } else {
        vault.bag.add(type_key, coin.into_balance());
    };
}

#[test_only]
/// Approve a coin type on a vault, bypassing the governance/intent flow. Use
/// from tests that only want the deposit-approval gate to pass; the production
/// path is `do_approve_coin_type` via a staged intent.
public fun approve_coin_type_for_testing<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    vault_name: String,
) {
    let vault: &mut Vault = account.borrow_managed_data_mut_with_package_witness(
        registry, VaultKey(vault_name), version::current_for_testing(),
    );
    let _ = approve_coin_type_internal<CoinType>(vault);
}

#[test_only]
/// Create a SpendingCap for testing (bypasses governance flow).
public fun create_spending_cap_for_testing(
    spending_limit_id: ID,
    account_id: ID,
    account_addr: address,
    vault_name: String,
    ctx: &mut TxContext,
): SpendingCap {
    SpendingCap {
        id: object::new(ctx),
        spending_limit_id,
        account_id,
        account_addr,
        vault_name,
    }
}
