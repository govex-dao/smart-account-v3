// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Authenticated users can lock a TreasuryCap in the Account to restrict minting and burning operations,
/// as well as modifying the coin metadata via Currency<T> and MetadataCap<T>.

module account_actions::currency;

public struct ExecutionProgressWitness has drop {}

use account_actions::actions_version as version;
use account_protocol::account::{Self, Account};
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use account_protocol::version_witness::VersionWitness;
use std::option;
use std::string::{Self, String};
use std::type_name::{Self, TypeName};
use sui::bcs;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, Currency, MetadataCap};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::url::{Self, Url};

// === Errors ===

const ENoChange: u64 = 0;
const EWrongValue: u64 = 1;
const EMintDisabled: u64 = 2;
const EBurnDisabled: u64 = 3;
const ECannotUpdateName: u64 = 4;
const ECannotUpdateSymbol: u64 = 5;
const ECannotUpdateDescription: u64 = 6;
const ECannotUpdateIcon: u64 = 7;
const EMaxSupply: u64 = 8;
const EUnsupportedActionVersion: u64 = 9;
const EAdminCapAccountMismatch: u64 = 10;
const ETreasuryCapNotLocked: u64 = 11;
const ECapIdMismatch: u64 = 12;
const EEmptyResourceName: u64 = 16;
const EResourceNameTooLong: u64 = 17;

const MAX_RESOURCE_NAME_LENGTH: u64 = 256;

// === Events ===

/// Emitted when coins are minted (execution)
public struct CurrencyMinted has copy, drop {
    account_id: ID,
    coin_type: TypeName,
    amount: u64,
    resource_name: String,
}

/// Emitted when coins are burned (execution)
public struct CurrencyBurned has copy, drop {
    account_id: ID,
    coin_type: TypeName,
    amount: u64,
}

/// Emitted when currency metadata is updated (execution)
public struct CurrencyMetadataUpdated has copy, drop {
    account_id: ID,
    coin_type: TypeName,
    symbol_updated: bool,
    name_updated: bool,
    description_updated: bool,
    icon_updated: bool,
}

/// Emitted when treasury cap is removed from account into executable_resources.
public struct TreasuryCapRemovedToResources has copy, drop {
    account_id: ID,
    coin_type: TypeName,
    resource_name: String,
}

/// Emitted when metadata cap is removed from account into executable_resources.
public struct MetadataCapRemovedToResources has copy, drop {
    account_id: ID,
    coin_type: TypeName,
    resource_name: String,
}

/// Emitted when treasury cap is locked in account via governance
public struct TreasuryCapLocked has copy, drop {
    account_id: ID,
    coin_type: TypeName,
}

/// Emitted when a delegated mint admin cap is created.
public struct CurrencyMintAdminCapMinted has copy, drop {
    account_id: ID,
    coin_type: TypeName,
    resource_name: String,
}

/// Emitted when metadata cap is locked in account via governance
public struct MetadataCapLocked has copy, drop {
    account_id: ID,
    coin_type: TypeName,
}

// === Action Type Markers ===
// CoinType is encoded in the marker to prevent executor from changing coin type

/// Mint new currency
public struct CurrencyMint<phantom CoinType> has drop {}
/// Burn currency
public struct CurrencyBurn<phantom CoinType> has drop {}
/// Update currency metadata
public struct CurrencyUpdate<phantom CoinType> has drop {}
/// Mint a delegated admin cap for a specific account + coin type
public struct MintCurrencyAdminCap<phantom CoinType> has drop {}
/// Remove treasury cap into executable_resources.
public struct RemoveTreasuryCapToResources<phantom CoinType> has drop {}
/// Remove metadata cap into executable_resources.
public struct RemoveMetadataCapToResources<phantom CoinType> has drop {}
/// Lock treasury cap via governance
public struct LockTreasuryCap<phantom CoinType> has drop {}
/// Lock metadata cap via governance
public struct LockMetadataCap<phantom CoinType> has drop {}

// === Factory Functions for Generic Marker Types ===
// These allow tests and other modules to create marker type instances

/// Create a CurrencyMint marker
public(package) fun currency_mint<CoinType>(): CurrencyMint<CoinType> { CurrencyMint {} }

/// Create a CurrencyBurn marker
public(package) fun currency_burn<CoinType>(): CurrencyBurn<CoinType> { CurrencyBurn {} }

/// Create a CurrencyUpdate marker
public(package) fun currency_update<CoinType>(): CurrencyUpdate<CoinType> { CurrencyUpdate {} }

/// Create a MintCurrencyAdminCap marker
public(package) fun mint_currency_admin_cap_marker<CoinType>(): MintCurrencyAdminCap<CoinType> {
    MintCurrencyAdminCap {}
}

/// Create a RemoveTreasuryCapToResources marker
public(package) fun remove_treasury_cap_to_resources<CoinType>(): RemoveTreasuryCapToResources<CoinType> {
    RemoveTreasuryCapToResources {}
}

/// Create a RemoveMetadataCapToResources marker
public(package) fun remove_metadata_cap_to_resources<CoinType>(): RemoveMetadataCapToResources<CoinType> {
    RemoveMetadataCapToResources {}
}

/// Create a LockTreasuryCap marker
public(package) fun lock_treasury_cap_marker<CoinType>(): LockTreasuryCap<CoinType> { LockTreasuryCap {} }

/// Create a LockMetadataCap marker
public(package) fun lock_metadata_cap_marker<CoinType>(): LockMetadataCap<CoinType> { LockMetadataCap {} }

/// Create a TreasuryCapKey witness (package-internal only)
public(package) fun treasury_cap_key<CoinType>(): TreasuryCapKey<CoinType> {
    TreasuryCapKey()
}

/// Create a MetadataCapKey witness (package-internal only)
public(package) fun metadata_cap_key<CoinType>(): MetadataCapKey<CoinType> {
    MetadataCapKey()
}

// === Structs ===

/// Dynamic Object Field key for the TreasuryCap.
public struct TreasuryCapKey<phantom CoinType>() has copy, drop, store;
/// Dynamic Object Field key for the MetadataCap.
public struct MetadataCapKey<phantom CoinType>() has copy, drop, store;
/// Dynamic Field key for the CurrencyRules.
public struct CurrencyRulesKey<phantom CoinType>() has copy, drop, store;
/// Dynamic Field wrapper restricting access to a TreasuryCap, permissions are disabled forever if set.
public struct CurrencyRules<phantom CoinType> has store {
    // coin can have a fixed supply, can_mint must be true to be able to mint more
    max_supply: Option<u64>,
    // total amount minted
    total_minted: u64,
    // total amount burned
    total_burned: u64,
    // permissions
    can_mint: bool,
    can_burn: bool,
    can_update_symbol: bool,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
}

/// Capability granting mint access for exactly one coin type on exactly one account.
public struct CurrencyMintAdminCap<phantom CoinType> has key, store {
    id: UID,
    account_id: ID,
}

/// Create a new CurrencyRules instance
public fun new_currency_rules<CoinType>(
    max_supply: Option<u64>,
    can_mint: bool,
    can_burn: bool,
    can_update_symbol: bool,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
): CurrencyRules<CoinType> {
    CurrencyRules {
        max_supply,
        total_minted: 0,
        total_burned: 0,
        can_mint,
        can_burn,
        can_update_symbol,
        can_update_name,
        can_update_description,
        can_update_icon,
    }
}

/// Create a CurrencyRulesKey witness (package-internal only)
public(package) fun currency_rules_key<CoinType>(): CurrencyRulesKey<CoinType> {
    CurrencyRulesKey()
}

// === Public functions ===

/// Checks if a TreasuryCap exists for a given coin type.
public fun has_cap<CoinType>(account: &Account): bool {
    account.has_managed_asset(TreasuryCapKey<CoinType>())
}

/// Checks if a MetadataCap exists for a given coin type.
public fun has_metadata_cap<CoinType>(account: &Account): bool {
    account.has_managed_asset(MetadataCapKey<CoinType>())
}

/// Borrows a mutable reference to the TreasuryCap for a given coin type.
/// WARNING: Bypasses CurrencyRules (max_supply, can_mint, total_minted).
/// Production code must use mint_with_admin_cap or do_init_mint instead.
#[test_only]
public fun borrow_treasury_cap_mut<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    caller_witness: VersionWitness,
): &mut TreasuryCap<CoinType> {
    account::assert_package_witness_authorized(account, registry, copy caller_witness);
    account.borrow_managed_asset_mut_with_package_witness(
        registry,
        TreasuryCapKey<CoinType>(),
        caller_witness,
    )
}

#[test_only]
/// Lock a TreasuryCap into an Account directly, bypassing the Executable flow.
/// Creates CurrencyRules with specified mint/burn permissions.
public fun lock_treasury_cap_for_testing<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    treasury_cap: TreasuryCap<CoinType>,
    can_mint: bool,
    can_burn: bool,
) {
    let rules = CurrencyRules<CoinType> {
        max_supply: option::none(),
        total_minted: treasury_cap.total_supply(),
        total_burned: 0,
        can_mint,
        can_burn,
        can_update_symbol: false,
        can_update_name: false,
        can_update_description: false,
        can_update_icon: false,
    };
    account::add_managed_data_with_package_witness(
        account, registry, CurrencyRulesKey<CoinType>(), rules, version::current_for_testing(),
    );
    account::add_managed_asset_with_package_witness(
        account, registry, TreasuryCapKey<CoinType>(), treasury_cap, version::current_for_testing(),
    );
}

/// Borrows the CurrencyRules for a given coin type.
public fun borrow_rules<CoinType>(
    account: &Account,
    registry: &PackageRegistry,
): &CurrencyRules<CoinType> {
    account.borrow_managed_data_with_package_witness(registry, CurrencyRulesKey<CoinType>(), version::current())
}

/// Validate CurrencyRules, record mint, and return minted coin.
/// The admin cap is the authorization token; package identity is not.
public fun mint_with_admin_cap<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    admin_cap: &CurrencyMintAdminCap<CoinType>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert!(admin_cap.account_id == object::id(account), EAdminCapAccountMismatch);

    let total_supply = coin_type_supply<CoinType>(account, registry);

    let rules: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut_with_package_witness(
        registry,
        CurrencyRulesKey<CoinType>(),
        version::current(),
    );

    validate_and_record_mint(rules, total_supply, amount);

    let cap: &mut TreasuryCap<CoinType> = account.borrow_managed_asset_mut_with_package_witness(
        registry,
        TreasuryCapKey<CoinType>(),
        version::current(),
    );

    cap.mint(amount, ctx)
}

/// Get the account ID bound to a CurrencyMintAdminCap.
public fun mint_admin_cap_account_id<CoinType>(cap: &CurrencyMintAdminCap<CoinType>): ID {
    cap.account_id
}

/// Destroy a CurrencyMintAdminCap once delegation is no longer needed.
public fun destroy_currency_mint_admin_cap<CoinType>(cap: CurrencyMintAdminCap<CoinType>) {
    let CurrencyMintAdminCap { id, account_id: _ } = cap;
    object::delete(id);
}

/// Returns the total supply of a given coin type.
public fun coin_type_supply<CoinType>(account: &Account, registry: &PackageRegistry): u64 {
    let cap: &TreasuryCap<CoinType> = account.borrow_managed_asset_with_package_witness(
        registry,
        TreasuryCapKey<CoinType>(),
        version::current(),
    );
    cap.total_supply()
}

/// Returns the maximum supply of a given coin type.
public fun max_supply<CoinType>(lock: &CurrencyRules<CoinType>): Option<u64> {
    lock.max_supply
}

/// Returns the total amount minted of a given coin type.
public fun total_minted<CoinType>(lock: &CurrencyRules<CoinType>): u64 {
    lock.total_minted
}

/// Returns the total amount burned of a given coin type.
public fun total_burned<CoinType>(lock: &CurrencyRules<CoinType>): u64 {
    lock.total_burned
}

/// Returns true if the coin type can mint.
public fun can_mint<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_mint
}

/// Returns true if the coin type can burn.
public fun can_burn<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_burn
}

/// Returns true if the coin type can update the symbol.
public fun can_update_symbol<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_symbol
}

/// Returns true if the coin type can update the name.
public fun can_update_name<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_name
}

/// Returns true if the coin type can update the description.
public fun can_update_description<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_description
}

/// Returns true if the coin type can update the icon.
public fun can_update_icon<CoinType>(lock: &CurrencyRules<CoinType>): bool {
    lock.can_update_icon
}

fun validate_and_record_mint<CoinType>(
    rules: &mut CurrencyRules<CoinType>,
    total_supply: u64,
    amount: u64,
) {
    assert!(rules.can_mint, EMintDisabled);
    if (rules.max_supply.is_some()) {
        assert!(amount <= std::u64::max_value!() - total_supply, EMaxSupply);
        assert!(amount + total_supply <= *rules.max_supply.borrow(), EMaxSupply);
    };
    assert!(amount <= std::u64::max_value!() - rules.total_minted, EMaxSupply);
    rules.total_minted = rules.total_minted + amount;
}

fun assert_valid_resource_name(resource_name: &String) {
    assert!(resource_name.length() > 0, EEmptyResourceName);
    assert!(resource_name.length() <= MAX_RESOURCE_NAME_LENGTH, EResourceNameTooLong);
}

/// Read metadata from a Currency object
/// Simple helper to extract all metadata fields in one call
/// Returns: (decimals, symbol, name, description, icon_url)
/// Note: icon_url returns empty string if not set
public fun read_currency_metadata<CoinType>(
    currency: &Currency<CoinType>,
): (u8, String, String, String, String) {
    (
        coin_registry::decimals(currency),
        coin_registry::symbol(currency),
        coin_registry::name(currency),
        coin_registry::description(currency),
        coin_registry::icon_url(currency),
    )
}

/// Anyone can burn coins they own if enabled.
public fun public_burn<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    coin: Coin<CoinType>,
) {
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut_with_package_witness(
        registry,
        CurrencyRulesKey<CoinType>(),
        version::current(),
    );
    assert!(rules_mut.can_burn, EBurnDisabled);
    assert!(coin.value() <= std::u64::max_value!() - rules_mut.total_burned, EWrongValue);
    rules_mut.total_burned = rules_mut.total_burned + coin.value();

    let cap_mut: &mut TreasuryCap<CoinType> = account.borrow_managed_asset_mut_with_package_witness(
        registry,
        TreasuryCapKey<CoinType>(),
        version::current(),
    );
    cap_mut.burn(coin);
}

// === Intent functions ===

/// Processes an UpdateAction, updates the Currency metadata.
/// Uses MetadataCap<T> stored in Account + shared Currency<T> object
public fun do_update<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    currency: &mut Currency<CoinType>,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CurrencyUpdate<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    let mut reader = bcs::new(*action_data);

    // Deserialize Option fields
    let symbol = if (bcs::peel_bool(&mut reader)) {
        option::some(std::string::utf8(bcs::peel_vec_u8(&mut reader)))
    } else {
        option::none()
    };

    let name = if (bcs::peel_bool(&mut reader)) {
        option::some(std::string::utf8(bcs::peel_vec_u8(&mut reader)))
    } else {
        option::none()
    };

    let description = if (bcs::peel_bool(&mut reader)) {
        option::some(std::string::utf8(bcs::peel_vec_u8(&mut reader)))
    } else {
        option::none()
    };

    let icon_url = if (bcs::peel_bool(&mut reader)) {
        option::some(std::string::utf8(bcs::peel_vec_u8(&mut reader)))
    } else {
        option::none()
    };

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
        registry,
        CurrencyRulesKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );

    assert!(
        symbol.is_some() || name.is_some() || description.is_some() || icon_url.is_some(),
        ENoChange,
    );

    // NOTE: Symbol is immutable in the Currency standard, so we always reject symbol updates
    assert!(symbol.is_none(), ECannotUpdateSymbol);
    if (!rules_mut.can_update_name) assert!(name.is_none(), ECannotUpdateName);
    if (!rules_mut.can_update_description) assert!(description.is_none(), ECannotUpdateDescription);
    if (!rules_mut.can_update_icon) assert!(icon_url.is_none(), ECannotUpdateIcon);

    // Get current values from Currency<T>
    let default_name = coin_registry::name(currency);
    let default_description = coin_registry::description(currency);
    let default_icon_url = coin_registry::icon_url(currency);

    // Borrow MetadataCap to update Currency metadata
    let metadata_cap: &MetadataCap<CoinType> = account.borrow_managed_asset_with_package_witness(
        registry,
        MetadataCapKey<CoinType>(),
        version::current(),
    );

    // Note: coin_registry uses set_* functions that take (currency, metadata_cap, value)
    // Symbol is immutable in the Currency standard, so we only update name, description, icon
    coin_registry::set_name(currency, metadata_cap, name.get_with_default(default_name));
    coin_registry::set_description(
        currency,
        metadata_cap,
        description.get_with_default(default_description),
    );
    coin_registry::set_icon_url(
        currency,
        metadata_cap,
        icon_url.get_with_default(default_icon_url),
    );

    event::emit(CurrencyMetadataUpdated {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
        symbol_updated: false, // Symbol is immutable in Currency standard
        name_updated: name.is_some(),
        description_updated: description.is_some(),
        icon_updated: icon_url.is_some(),
    });

    // Increment action index
    executable::increment_action_idx<_, CurrencyUpdate<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Processes a MintAction for init actions, mints coins and stores in executable_resources.
/// DETERMINISTIC: Stores minted coin in executable_resources for subsequent actions.
/// The resource_name in ActionSpec tells us where to store the coin.
public fun do_init_mint<Outcome: store, CoinType, IW: drop>(
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
    account_protocol::action_validation::assert_action_type<CurrencyMint<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // ActionSpec contains: amount, resource_name (where to store minted coin)
    let mut reader = bcs::new(*action_data);
    let amount = bcs::peel_u64(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);

    // Check rules and mint
    let total_supply = coin_type_supply<CoinType>(account, registry);
    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
        registry,
        CurrencyRulesKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );

    validate_and_record_mint(rules_mut, total_supply, amount);

    let cap_mut: &mut TreasuryCap<CoinType> = account.borrow_managed_asset_mut(
        registry,
        TreasuryCapKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );

    // Mint the coin
    let coin = cap_mut.mint(amount, ctx);

    // Store coin in executable_resources for subsequent actions (e.g., CreateVesting)
    executable_resources::provide_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        coin,
        ctx,
    );

    event::emit(CurrencyMinted {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
        amount,
        resource_name,
    });

    // Increment action index
    executable::increment_action_idx<_, CurrencyMint<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Processes a MintCurrencyAdminCap action and stores the cap in executable_resources.
/// The next action can take the cap and either store it in a long-lived object or consume it
/// for one-shot delegated minting.
public fun do_mint_currency_admin_cap<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<MintCurrencyAdminCap<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(has_cap<CoinType>(account), ETreasuryCapNotLocked);
    let rules = borrow_rules<CoinType>(account, registry);
    assert!(rules.can_mint, EMintDisabled);

    let cap = CurrencyMintAdminCap<CoinType> {
        id: object::new(ctx),
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

    event::emit(CurrencyMintAdminCapMinted {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
        resource_name,
    });

    executable::increment_action_idx<_, MintCurrencyAdminCap<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Processes a BurnAction, burns coins taken from executable_resources.
/// DETERMINISTIC: Takes coin from executable_resources (from previous action), NOT from PTB!
/// The resource_name in ActionSpec tells us which resource to take.
public fun do_init_burn<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<CurrencyBurn<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // ActionSpec contains: amount, resource_name (where to take coin from)
    let mut reader = bcs::new(*action_data);
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

    assert!(amount == coin.value(), EWrongValue);

    // Capture account_id before mutable borrows
    let account_id = object::id(account);

    let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
        registry,
        CurrencyRulesKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(rules_mut.can_burn, EBurnDisabled);

    assert!(amount <= std::u64::max_value!() - rules_mut.total_burned, EWrongValue);
    rules_mut.total_burned = rules_mut.total_burned + amount;

    let cap_mut: &mut TreasuryCap<CoinType> = account.borrow_managed_asset_mut(
        registry,
        TreasuryCapKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(CurrencyBurned {
        account_id,
        coin_type: type_name::get<CoinType>(),
        amount,
    });

    // Increment action index
    executable::increment_action_idx<_, CurrencyBurn<CoinType>, _>(executable, registry, ExecutionProgressWitness {});

    cap_mut.burn(coin);
}

/// Init action: remove TreasuryCap from Account into executable_resources.
///
/// A later approved action must consume the cap, for example `transfer::do_init_transfer`
/// to return it to a creator or `do_init_lock_treasury_cap` to lock it elsewhere.
public fun do_init_remove_treasury_cap_to_resources<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // 1. Assert account ownership
    executable.intent().assert_is_account(account.addr());

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<RemoveTreasuryCapToResources<CoinType>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize RemoveTreasuryCapToResourcesAction from BCS bytes
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // 5. Validate all bytes consumed (security)
    bcs_validation::validate_all_bytes_consumed(reader);
    assert_valid_resource_name(&resource_name);

    // 6. Extract TreasuryCap from Account
    let treasury_cap = account::remove_managed_asset<
        TreasuryCapKey<CoinType>,
        TreasuryCap<CoinType>,
        Outcome,
        ExecutionProgressWitness,
    >(
        account,
        registry,
        TreasuryCapKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(object::id(&treasury_cap) == expected_cap_id, ECapIdMismatch);

    // 7. Only remove CurrencyRules if no MetadataCap is retained.
    // If MetadataCap is still locked, do_update needs CurrencyRules to check permissions.
    if (!has_metadata_cap<CoinType>(account)) {
        let rules = account::remove_managed_data<
            CurrencyRulesKey<CoinType>,
            CurrencyRules<CoinType>,
            Outcome,
            ExecutionProgressWitness,
        >(
            account,
            registry,
            CurrencyRulesKey<CoinType>(),
            executable,
            ExecutionProgressWitness {},
        );

        // 8. Properly destroy the CurrencyRules struct
        let CurrencyRules {
            max_supply: _,
            total_minted: _,
            total_burned: _,
            can_mint: _,
            can_burn: _,
            can_update_symbol: _,
            can_update_name: _,
            can_update_description: _,
            can_update_icon: _,
        } = rules;
    } else {
        // MetadataCap still present — disable mint/burn but keep rules for metadata updates
        let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
            registry,
            CurrencyRulesKey<CoinType>(),
            executable,
            ExecutionProgressWitness {},
        );
        rules_mut.can_mint = false;
        rules_mut.can_burn = false;
    };

    // 9. Route TreasuryCap to executable_resources for a subsequent approved action.
    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        treasury_cap,
        ctx,
    );

    event::emit(TreasuryCapRemovedToResources {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
        resource_name,
    });

    // 10. Increment action index
    executable::increment_action_idx<_, RemoveTreasuryCapToResources<CoinType>, _>(
        executable,
        registry,
        ExecutionProgressWitness {},
    );
}

/// Init action: remove MetadataCap from Account into executable_resources.
///
/// A later approved action must consume the cap, for example `transfer::do_init_transfer`
/// to return it to a creator or `do_init_lock_metadata_cap` to lock it elsewhere.
public fun do_init_remove_metadata_cap_to_resources<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // 1. Assert account ownership
    executable.intent().assert_is_account(account.addr());

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<RemoveMetadataCapToResources<CoinType>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize RemoveMetadataCapToResourcesAction from BCS bytes
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // 5. Validate all bytes consumed (security)
    bcs_validation::validate_all_bytes_consumed(reader);
    assert_valid_resource_name(&resource_name);

    // 6. Remove MetadataCap from account
    let metadata_cap = account::remove_managed_asset<
        MetadataCapKey<CoinType>,
        MetadataCap<CoinType>,
        Outcome,
        ExecutionProgressWitness,
    >(
        account,
        registry,
        MetadataCapKey<CoinType>(),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(object::id(&metadata_cap) == expected_cap_id, ECapIdMismatch);

    // 7. Clean up or update CurrencyRules based on TreasuryCap presence
    // Reciprocal to do_init_remove_treasury_cap_to_resources's MetadataCap check
    if (!has_cap<CoinType>(account)) {
        // No TreasuryCap — CurrencyRules are orphaned, remove them
        if (account.has_managed_data(CurrencyRulesKey<CoinType>())) {
            let rules = account::remove_managed_data<
                CurrencyRulesKey<CoinType>,
                CurrencyRules<CoinType>,
                Outcome,
                ExecutionProgressWitness,
            >(
                account,
                registry,
                CurrencyRulesKey<CoinType>(),
                executable,
                ExecutionProgressWitness {},
            );
            let CurrencyRules {
                max_supply: _,
                total_minted: _,
                total_burned: _,
                can_mint: _,
                can_burn: _,
                can_update_symbol: _,
                can_update_name: _,
                can_update_description: _,
                can_update_icon: _,
            } = rules;
        };
    } else {
        // TreasuryCap still present — disable metadata updates but keep rules for mint/burn
        let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
            registry,
            CurrencyRulesKey<CoinType>(),
            executable,
            ExecutionProgressWitness {},
        );
        rules_mut.can_update_symbol = false;
        rules_mut.can_update_name = false;
        rules_mut.can_update_description = false;
        rules_mut.can_update_icon = false;
    };

    // 8. Route MetadataCap to executable_resources for a subsequent approved action.
    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        metadata_cap,
        ctx,
    );

    event::emit(MetadataCapRemovedToResources {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
        resource_name,
    });

    // 9. Increment action index
    executable::increment_action_idx<_, RemoveMetadataCapToResources<CoinType>, _>(
        executable,
        registry,
        ExecutionProgressWitness {},
    );
}

/// Init action: Lock TreasuryCap in Account via governance
/// Follows the 3-layer action execution pattern (see IMPORTANT_ACTION_EXECUTION_PATTERN.md)
/// Used when a DAO acquires a new TreasuryCap and wants to manage it.
/// TreasuryCap must already be in executable_resources under resource_name
/// (via ProvideObjectToResources or OwnedWithdrawObject).
/// ActionSpec data: has_max_supply (bool), max_supply (u64), can_mint (bool), can_burn (bool),
///   can_update_name (bool), can_update_description (bool), can_update_icon (bool), resource_name (String)
public fun do_init_lock_treasury_cap<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    // 1. Assert account ownership
    executable.intent().assert_is_account(account.addr());

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<LockTreasuryCap<CoinType>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize LockTreasuryCapAction from BCS bytes
    // NOTE: Serialization ALWAYS writes both has_max_supply (bool) and max_supply (u64)
    // so we must ALWAYS peel both fields to consume all bytes
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let has_max_supply = bcs::peel_bool(&mut reader);
    let max_supply_value = bcs::peel_u64(&mut reader); // Always peel to match serialization
    let max_supply = if (has_max_supply) {
        option::some(max_supply_value)
    } else {
        option::none()
    };
    let can_mint = bcs::peel_bool(&mut reader);
    let can_burn = bcs::peel_bool(&mut reader);
    let can_update_name = bcs::peel_bool(&mut reader);
    let can_update_description = bcs::peel_bool(&mut reader);
    let can_update_icon = bcs::peel_bool(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // 5. Validate all bytes consumed (security)
    bcs_validation::validate_all_bytes_consumed(reader);

    // 5b. Take TreasuryCap from executable_resources
    let treasury_cap: TreasuryCap<CoinType> = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    // 6. Create CurrencyRules with specified max_supply and permission flags
    // M2 fix: validate max_supply >= current circulating supply
    let current_supply = treasury_cap.total_supply();
    if (max_supply.is_some()) {
        assert!(current_supply <= *max_supply.borrow(), EMaxSupply);
    };

    // 7. Store or update CurrencyRules in account
    // CurrencyRules may already exist if MetadataCap was locked first — update instead of add
    if (account.has_managed_data(CurrencyRulesKey<CoinType>())) {
        let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
            registry,
            CurrencyRulesKey<CoinType>(),
            executable,
            ExecutionProgressWitness {},
        );
        rules_mut.max_supply = max_supply;
        rules_mut.total_minted = current_supply;
        rules_mut.total_burned = 0;
        // Direct assignment: the governance proposal explicitly specifies desired permissions.
        // Previous code used && which created a one-way ratchet — once false, permanently false,
        // even across cap rotation (unlock → re-lock).
        rules_mut.can_mint = can_mint;
        rules_mut.can_burn = can_burn;
        rules_mut.can_update_symbol = false;
        rules_mut.can_update_name = can_update_name;
        rules_mut.can_update_description = can_update_description;
        rules_mut.can_update_icon = can_update_icon;
    } else {
        let rules = CurrencyRules<CoinType> {
            max_supply,
            total_minted: current_supply,
            total_burned: 0,
            can_mint,
            can_burn,
            can_update_symbol: false,
            can_update_name,
            can_update_description,
            can_update_icon,
        };
        account.add_managed_data(
            registry,
            CurrencyRulesKey<CoinType>(),
            rules,
            executable,
            ExecutionProgressWitness {},
        );
    };
    account::add_managed_asset(
        account,
        registry,
        TreasuryCapKey<CoinType>(),
        treasury_cap,
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(TreasuryCapLocked {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
    });

    // 8. Increment action index
    executable::increment_action_idx<_, LockTreasuryCap<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Init action: Lock MetadataCap in Account via governance
/// Follows the 3-layer action execution pattern (see IMPORTANT_ACTION_EXECUTION_PATTERN.md)
/// Used when a DAO acquires a new MetadataCap and wants to manage it.
/// MetadataCap must already be in executable_resources under resource_name
/// (via ProvideObjectToResources or OwnedWithdrawObject).
/// ActionSpec data: can_update_name (bool), can_update_description (bool), can_update_icon (bool), resource_name (String)
public fun do_init_lock_metadata_cap<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    // 1. Assert account ownership
    executable.intent().assert_is_account(account.addr());

    // 2. Get current ActionSpec from Executable
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<LockMetadataCap<CoinType>>(action_spec);

    // 3. Check version
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // 4. Deserialize LockMetadataCapAction from BCS bytes
    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let can_update_name = bcs::peel_bool(&mut reader);
    let can_update_description = bcs::peel_bool(&mut reader);
    let can_update_icon = bcs::peel_bool(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // 5. Validate all bytes consumed (security)
    bcs_validation::validate_all_bytes_consumed(reader);

    // 5b. Take MetadataCap from executable_resources
    let metadata_cap: MetadataCap<CoinType> = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    // 6. Create CurrencyRules if they don't already exist (metadata-only locking)
    // Without CurrencyRules, do_update would abort when trying to borrow them.
    // can_mint/can_burn default to false — no TreasuryCap is locked yet, so these
    // will be set correctly when do_init_lock_treasury_cap runs.
    if (!account.has_managed_data(CurrencyRulesKey<CoinType>())) {
        let rules = CurrencyRules<CoinType> {
            max_supply: option::none(),
            total_minted: 0,
            total_burned: 0,
            can_mint: false,
            can_burn: false,
            can_update_symbol: false,
            can_update_name,
            can_update_description,
            can_update_icon,
        };
        account.add_managed_data(
            registry,
            CurrencyRulesKey<CoinType>(),
            rules,
            executable,
            ExecutionProgressWitness {},
        );
    } else {
        // Rules already exist: update metadata permissions to match ActionSpec.
        // For cap rotation (unlock → re-lock), the DAO explicitly passes the
        // desired permissions rather than unconditionally forcing them to true.
        let rules_mut: &mut CurrencyRules<CoinType> = account.borrow_managed_data_mut(
            registry, CurrencyRulesKey<CoinType>(), executable, ExecutionProgressWitness {},
        );
        // Direct assignment: same fix as TreasuryCap re-lock.
        // Previous && created permanent permission loss across cap rotation.
        rules_mut.can_update_symbol = false;
        rules_mut.can_update_name = can_update_name;
        rules_mut.can_update_description = can_update_description;
        rules_mut.can_update_icon = can_update_icon;
    };

    // 7. Store MetadataCap in account
    account::add_managed_asset(
        account,
        registry,
        MetadataCapKey<CoinType>(),
        metadata_cap,
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(MetadataCapLocked {
        account_id: object::id(account),
        coin_type: type_name::get<CoinType>(),
    });

    // 8. Increment action index
    executable::increment_action_idx<_, LockMetadataCap<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

#[test_only]
public fun create_mint_admin_cap_for_testing<CoinType>(
    account_id: ID,
    ctx: &mut TxContext,
): CurrencyMintAdminCap<CoinType> {
    CurrencyMintAdminCap {
        id: object::new(ctx),
        account_id,
    }
}
