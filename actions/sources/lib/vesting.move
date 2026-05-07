// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Standalone vesting module with TRUE FUND ISOLATION.
///
/// Key difference from vault streams:
/// - Funds are PHYSICALLY MOVED to a shared Vesting object on creation
/// - Cannot be drained by vault operations or other DAO spending
/// - Uncancellable vestings are GUARANTEED to recipient
///
/// Features (matching vault streams):
/// - Iteration-based vesting (discrete unlock events)
/// - VestingCap-based claiming (transferable via Sui object transfer)
/// - Cancellable setting

module account_actions::vesting;

public struct ExecutionProgressWitness has drop {}

use account_actions::actions_version as version;
use account_actions::stream_utils;
use account_protocol::account::{Self, Account};
use account_protocol::action_validation;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::balance::Balance;
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::vec_map::{Self, VecMap};

// === Errors ===

const EBalanceNotEmpty: u64 = 0;
const ETooEarly: u64 = 1;
const EWrongVesting: u64 = 2;
const EVestingOver: u64 = 3;
const ENotCancellable: u64 = 4;
const EUnsupportedActionVersion: u64 = 6;
const EUnauthorized: u64 = 7;
const EVestingCapMismatch: u64 = 8;
const EInsufficientVestedAmount: u64 = 10;
const EInvalidParameters: u64 = 15;
const EAmountMustBeGreaterThanZero: u64 = 16;
const EAmountMismatch: u64 = 17;
const EZeroBeneficiary: u64 = 19; // beneficiary must not be @0x0 (funds would be permanently locked)
const EMaxVestingsExceeded: u64 = 20; // registry has reached MAX_VESTINGS capacity
const EVestingStillActive: u64 = 21; // VestingCap cannot be destroyed while registry still tracks vesting
const EVestingRegistryMissing: u64 = 22; // VestingCap destruction requires registry proof

const MAX_VESTINGS: u64 = 100;

// === Action Type Markers ===
// CoinType is encoded in the marker to prevent executor from changing coin type

/// Create a new vesting
public struct CreateVesting<phantom CoinType> has drop {}
/// Cancel a vesting (if cancellable)
public struct CancelVesting<phantom CoinType> has drop {}

// === Factory Functions for Generic Marker Types ===

/// Package-private to prevent external code from obtaining drop-typed values
public(package) fun create_vesting<CoinType>(): CreateVesting<CoinType> { CreateVesting {} }

/// Package-private to prevent external code from obtaining drop-typed values
public(package) fun cancel_vesting<CoinType>(): CancelVesting<CoinType> { CancelVesting {} }

// === Registry Structs ===

/// Key for storing the VestingRegistry as managed data on the Account
public struct VestingRegistryKey has copy, drop, store {}

/// Metadata entry for a single vesting.
public struct VestingEntry has copy, drop, store {
    coin_type: TypeName,
    is_cancellable: bool,
}

/// On-chain index of active vestings for a DAO account.
/// Stored as managed data (not managed asset) under VestingRegistryKey.
/// VecMap so the entire registry is readable in a single RPC call.
public struct VestingRegistry has store {
    entries: VecMap<ID, VestingEntry>,
}

// === Structs ===

/// Capability object for vesting beneficiaries. 1:1 with Vesting.
/// Transferred to beneficiary on vesting creation.
/// Borrowed for claim authorization. Transferable via Sui object transfer.
public struct VestingCap has key, store {
    id: UID,
    vesting_id: ID,
    account_id: ID,
    dao_address: address,
}

/// Shared object holding locked funds with iteration-based vesting schedule.
/// TRUE ISOLATION: funds live here, completely separate from vault.
public struct Vesting<phantom CoinType> has key {
    id: UID,
    /// The DAO account this vesting belongs to
    dao_address: address,
    /// Remaining balance to be vested
    balance: Balance<CoinType>,
    /// Coin type for verification
    coin_type: TypeName,
    // === Iteration-based vesting parameters ===
    /// Tokens that unlock per iteration (NO DIVISION - exact amount)
    amount_per_iteration: u64,
    /// Total claimed so far
    claimed_amount: u64,
    /// First iteration index not yet fully claimed (for precise window tracking)
    first_unclaimed_iteration: u64,
    /// Partial claim amount within the first_unclaimed_iteration
    partial_claimed_in_iteration: u64,
    /// When vesting starts
    start_time: u64,
    /// Number of unlock events
    iterations_total: u64,
    /// Time between unlocks (ms)
    iteration_period_ms: u64,
    // === Settings ===
    /// Can DAO cancel this? (false = GUARANTEED to recipient)
    is_cancellable: bool,
    /// Optional metadata
    metadata: Option<String>,
}

// === Events ===

public struct VestingCreated has copy, drop {
    vesting_id: ID,
    cap_id: ID,
    account_id: address,
    coin_type: TypeName,
    beneficiary: address,
    total_amount: u64,
    amount_per_iteration: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    start_time: u64,
    is_cancellable: bool,
}

public struct VestingClaimed has copy, drop {
    vesting_id: ID,
    account_id: address,
    coin_type: TypeName,
    claimer: address,
    amount: u64,
    remaining_balance: u64,
    total_claimed: u64,
}

public struct VestingCancelled has copy, drop {
    vesting_id: ID,
    account_id: address,
    coin_type: TypeName,
    refunded_to_dao: u64,
}

// === Public Functions: Claiming ===

/// VestingCap holder claims unlocked funds.
public fun claim<CoinType>(
    vesting: &mut Vesting<CoinType>,
    cap: &VestingCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert!(cap.vesting_id == vesting.id.to_inner(), EVestingCapMismatch);
    assert!(cap.dao_address == vesting.dao_address, EVestingCapMismatch);

    do_claim_internal(vesting, amount, clock, ctx)
}

/// Internal claim logic shared by both claim functions
fun do_claim_internal<CoinType>(
    vesting: &mut Vesting<CoinType>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<CoinType> {
    assert!(amount > 0, EAmountMustBeGreaterThanZero);
    let current_time = clock.timestamp_ms();

    // Check start time
    assert!(current_time >= vesting.start_time, ETooEarly);

    // Check balance
    assert!(vesting.balance.value() > 0, EVestingOver);

    // Calculate available using precise iteration tracking
    let claim_window = option::none();
    let (available, adj_first, adj_partial) = stream_utils::calculate_available_with_tracking(
        vesting.amount_per_iteration,
        vesting.first_unclaimed_iteration,
        vesting.partial_claimed_in_iteration,
        vesting.start_time,
        vesting.iterations_total,
        vesting.iteration_period_ms,
        current_time,
        &claim_window,
    );

    assert!(available >= amount, EInsufficientVestedAmount);
    assert!(vesting.balance.value() >= amount, EInsufficientVestedAmount);

    // Update tracking state: advance past forfeited, then consume claimed amount
    let (new_first, new_partial) = stream_utils::advance_claim_tracking(
        adj_first,
        adj_partial,
        amount,
        vesting.amount_per_iteration,
    );
    vesting.first_unclaimed_iteration = new_first;
    vesting.partial_claimed_in_iteration = new_partial;
    vesting.claimed_amount = vesting.claimed_amount + amount;

    let remaining = vesting.balance.value() - amount;

    event::emit(VestingClaimed {
        vesting_id: vesting.id.to_inner(),
        account_id: vesting.dao_address,
        coin_type: type_name::get<CoinType>(),
        claimer: ctx.sender(),
        amount,
        remaining_balance: remaining,
        total_claimed: vesting.claimed_amount,
    });

    coin::from_balance(vesting.balance.split(amount), ctx)
}

// === Destruction ===

/// Destroy vesting and its cap when fully claimed.
/// Cap must match the vesting — prevents premature cap destruction that would lock funds.
/// Cleans up the VestingRegistry entry so the DAO's vesting slot is freed.
public fun destroy_empty<CoinType>(
    vesting: Vesting<CoinType>,
    cap: VestingCap,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    let Vesting { id, balance, .. } = vesting;
    let vesting_id = id.to_inner();
    assert!(cap.vesting_id == vesting_id, EVestingCapMismatch);
    assert!(cap.dao_address == account.addr(), EVestingCapMismatch);
    assert!(balance.value() == 0, EBalanceNotEmpty);

    // Clean up registry entry (permissionless via package witness)
    if (account.has_managed_data(VestingRegistryKey {})) {
        let registry_mut: &mut VestingRegistry =
            account.borrow_managed_data_mut_with_package_witness(
                registry,
                VestingRegistryKey {},
                version::current(),
            );
        if (registry_mut.entries.contains(&vesting_id)) {
            registry_mut.entries.remove(&vesting_id);
        };
    };

    balance.destroy_zero();
    id.delete();
    let VestingCap { id: cap_id, vesting_id: _, account_id: _, dao_address: _ } = cap;
    cap_id.delete();
}

/// Destroy an orphaned VestingCap (e.g. after the DAO cancelled the vesting or
/// the depleted vesting was cleaned from the registry). Anyone holding the cap
/// can call this, but the DAO registry must prove the vesting is no longer active.
public fun destroy_vesting_cap(
    cap: VestingCap,
    account: &Account,
    registry: &PackageRegistry,
) {
    let VestingCap { id, vesting_id, account_id, dao_address } = cap;
    assert!(account_id == object::id(account), EVestingCapMismatch);
    assert!(dao_address == account.addr(), EVestingCapMismatch);
    assert!(account.has_managed_data(VestingRegistryKey {}), EVestingRegistryMissing);

    let registry_ref: &VestingRegistry =
        account.borrow_managed_data_with_package_witness(
            registry,
            VestingRegistryKey {},
            version::current(),
        );
    assert!(!registry_ref.entries.contains(&vesting_id), EVestingStillActive);
    id.delete();
}

/// Permissionless cleanup: remove a fully-depleted vesting from the registry.
/// Fixes the DoS vector where a beneficiary destroys their cap (via destroy_vesting_cap)
/// without calling destroy_empty, orphaning the registry entry permanently.
/// Anyone can call this as long as the vesting balance is zero.
public fun cleanup_depleted_vesting<CoinType>(
    vesting: &Vesting<CoinType>,
    account: &mut Account,
    registry: &PackageRegistry,
) {
    assert!(vesting.dao_address == account.addr(), EUnauthorized);
    assert!(vesting.balance.value() == 0, EBalanceNotEmpty);

    let vesting_id = object::id(vesting);
    if (account.has_managed_data(VestingRegistryKey {})) {
        let registry_mut: &mut VestingRegistry =
            account.borrow_managed_data_mut_with_package_witness(
                registry,
                VestingRegistryKey {},
                version::current(),
            );
        if (registry_mut.entries.contains(&vesting_id)) {
            registry_mut.entries.remove(&vesting_id);
        };
    };
}

// === Intent Execution Functions ===

/// Execute CreateVesting from intent
/// Takes coin from executable_resources (from prior VaultSpend action)
public fun do_create_vesting<Config: store, Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(account, registry, executable, ExecutionProgressWitness {});

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    action_validation::assert_action_type<CreateVesting<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);

    // Deserialize CreateVestingAction
    let beneficiary = bcs::peel_address(&mut reader);
    let amount_per_iteration = bcs::peel_u64(&mut reader);

    // Deserialize Option<u64> for start_time (None = use clock time)
    let start_time_opt = if (bcs::peel_bool(&mut reader)) {
        option::some(bcs::peel_u64(&mut reader))
    } else {
        option::none()
    };

    let iterations_total = bcs::peel_u64(&mut reader);
    let iteration_period_ms = bcs::peel_u64(&mut reader);

    let is_cancellable = bcs::peel_bool(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(beneficiary != @0x0, EZeroBeneficiary);

    // Resolve start_time: use provided value or clock time
    let start_time = if (start_time_opt.is_some()) {
        *start_time_opt.borrow()
    } else {
        clock.timestamp_ms()
    };

    // Validate parameters
    let current_time = clock.timestamp_ms();
    let claim_window: Option<u64> = option::none();
    assert!(
        stream_utils::validate_iteration_parameters(
            start_time,
            iterations_total,
            iteration_period_ms,
            &claim_window,
            current_time,
        ),
        EInvalidParameters,
    );
    assert!(amount_per_iteration > 0, EAmountMustBeGreaterThanZero);

    // Take coin from executable_resources (from prior action like VaultSpend)
    let coin: Coin<CoinType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    // Verify amount matches expected total
    let expected_total = (amount_per_iteration as u128) * (iterations_total as u128);
    assert!(expected_total <= (18446744073709551615 as u128), EInvalidParameters);
    assert!(coin.value() == (expected_total as u64), EAmountMismatch);

    let total_amount = coin.value();
    let vesting_uid = object::new(ctx);
    let vesting_id = vesting_uid.to_inner();

    // Lazily initialize vesting registry if it doesn't exist
    if (!account.has_managed_data(VestingRegistryKey {})) {
        account.add_managed_data(
            registry,
            VestingRegistryKey {},
            VestingRegistry { entries: vec_map::empty() },
            executable,
            ExecutionProgressWitness {},
        );
    };

    // Register vesting in the registry (cap at MAX_VESTINGS to prevent VecMap size explosion)
    let registry_mut: &mut VestingRegistry = account.borrow_managed_data_mut(
        registry,
        VestingRegistryKey {},
        executable,
        ExecutionProgressWitness {},
    );
    assert!(registry_mut.entries.size() < MAX_VESTINGS, EMaxVestingsExceeded);
    registry_mut.entries.insert(vesting_id, VestingEntry {
        coin_type: type_name::get<CoinType>(),
        is_cancellable,
    });

    // Create and share the Vesting object - FUNDS ARE NOW ISOLATED
    transfer::share_object(Vesting<CoinType> {
        id: vesting_uid,
        dao_address: account.addr(),
        balance: coin.into_balance(),
        coin_type: type_name::get<CoinType>(),
        amount_per_iteration,
        claimed_amount: 0,
        first_unclaimed_iteration: 0,
        partial_claimed_in_iteration: 0,
        start_time,
        iterations_total,
        iteration_period_ms,
        is_cancellable,
        metadata: option::none(),
    });

    // Mint VestingCap and transfer to beneficiary
    let cap = VestingCap {
        id: object::new(ctx),
        vesting_id,
        account_id: object::id(account),
        dao_address: account.addr(),
    };
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, beneficiary);

    event::emit(VestingCreated {
        vesting_id,
        cap_id,
        account_id: account.addr(),
        coin_type: type_name::get<CoinType>(),
        beneficiary,
        total_amount,
        amount_per_iteration,
        iterations_total,
        iteration_period_ms,
        start_time,
        is_cancellable,
    });

    executable::increment_action_idx<_, CreateVesting<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute CancelVesting from intent
/// Refund is provided to executable_resources under the resource_name from ActionSpec
/// for consumption by subsequent actions (e.g., VaultDeposit to return funds)
public fun do_cancel_vesting<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    vesting: Vesting<CoinType>,
    _clock: &Clock,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    account::assert_execution_authorized(account, registry, executable, ExecutionProgressWitness {});

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    action_validation::assert_action_type<CancelVesting<CoinType>>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);

    let expected_vesting_id = bcs::peel_address(&mut reader).to_id();
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    bcs_validation::validate_all_bytes_consumed(reader);

    // Verify correct vesting
    assert!(object::id(&vesting) == expected_vesting_id, EWrongVesting);
    assert!(vesting.dao_address == account.addr(), EUnauthorized);
    assert!(vesting.is_cancellable, ENotCancellable);

    // Remove entry from vesting registry
    if (account.has_managed_data(VestingRegistryKey {})) {
        let registry_mut: &mut VestingRegistry = account.borrow_managed_data_mut(
            registry,
            VestingRegistryKey {},
            executable,
            ExecutionProgressWitness {},
        );
        if (registry_mut.entries.contains(&expected_vesting_id)) {
            registry_mut.entries.remove(&expected_vesting_id);
        };
    };

    let Vesting {
        id,
        dao_address,
        balance,
        coin_type: _,
        amount_per_iteration: _,
        claimed_amount: _,
        first_unclaimed_iteration: _,
        partial_claimed_in_iteration: _,
        start_time: _,
        iterations_total: _,
        iteration_period_ms: _,
        is_cancellable: _,
        metadata: _,
    } = vesting;

    let refunded = balance.value();

    event::emit(VestingCancelled {
        vesting_id: id.to_inner(),
        account_id: dao_address,
        coin_type: type_name::get<CoinType>(),
        refunded_to_dao: refunded,
    });

    id.delete();

    // Return ALL remaining balance to DAO via executable_resources
    // (cap holder should have claimed vested funds before cancel)
    let refund_coin = coin::from_balance(balance, ctx);
    executable_resources::provide_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        refund_coin,
        ctx,
    );

    executable::increment_action_idx<_, CancelVesting<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

// === View Functions ===

public fun balance_value<CoinType>(self: &Vesting<CoinType>): u64 {
    self.balance.value()
}

public fun vesting_dao<CoinType>(self: &Vesting<CoinType>): address {
    self.dao_address
}

public fun vesting_is_cancellable<CoinType>(self: &Vesting<CoinType>): bool {
    self.is_cancellable
}

public fun vesting_claimed_amount<CoinType>(self: &Vesting<CoinType>): u64 {
    self.claimed_amount
}

public fun vesting_iterations_total<CoinType>(self: &Vesting<CoinType>): u64 {
    self.iterations_total
}

public fun vesting_amount_per_iteration<CoinType>(self: &Vesting<CoinType>): u64 {
    self.amount_per_iteration
}

public fun vesting_iteration_period_ms<CoinType>(self: &Vesting<CoinType>): u64 {
    self.iteration_period_ms
}

public fun vesting_start_time<CoinType>(self: &Vesting<CoinType>): u64 {
    self.start_time
}

public fun vesting_metadata<CoinType>(self: &Vesting<CoinType>): &Option<String> {
    &self.metadata
}

// === Registry View Functions ===

public fun has_vesting_registry(account: &Account): bool {
    account.has_managed_data(VestingRegistryKey {})
}

public fun vesting_registry_entries(
    account: &Account,
    registry: &PackageRegistry,
): &VecMap<ID, VestingEntry> {
    let reg: &VestingRegistry = account.borrow_managed_data_with_package_witness(
        registry,
        VestingRegistryKey {},
        version::current(),
    );
    &reg.entries
}

public fun vesting_entry_coin_type(entry: &VestingEntry): TypeName {
    entry.coin_type
}

public fun vesting_entry_is_cancellable(entry: &VestingEntry): bool {
    entry.is_cancellable
}

// === VestingCap Accessors ===

public fun vesting_cap_vesting_id(cap: &VestingCap): ID { cap.vesting_id }
public fun vesting_cap_account_id(cap: &VestingCap): ID { cap.account_id }
public fun vesting_cap_dao_address(cap: &VestingCap): address { cap.dao_address }

/// Calculate currently claimable amount
public fun calculate_claimable<CoinType>(vesting: &Vesting<CoinType>, clock: &Clock): u64 {
    let claim_window = option::none();
    let (available, _, _) = stream_utils::calculate_available_with_tracking(
        vesting.amount_per_iteration,
        vesting.first_unclaimed_iteration,
        vesting.partial_claimed_in_iteration,
        vesting.start_time,
        vesting.iterations_total,
        vesting.iteration_period_ms,
        clock.timestamp_ms(),
        &claim_window,
    );
    available
}

/// Get total vesting amount (amount_per_iteration * iterations_total)
/// Asserts if the result would overflow u64
public fun total_amount<CoinType>(vesting: &Vesting<CoinType>): u64 {
    let total = (vesting.amount_per_iteration as u128) * (vesting.iterations_total as u128);
    assert!(total <= (18446744073709551615 as u128), EInvalidParameters); // u64::MAX check
    (total as u64)
}

/// Get next vesting time
public fun next_vest_time<CoinType>(vesting: &Vesting<CoinType>, clock: &Clock): Option<u64> {
    let current_time = clock.timestamp_ms();

    // Before start: first unlock is at start_time + iteration_period_ms
    // (at start_time exactly, 0 iterations have completed so nothing is claimable)
    if (current_time < vesting.start_time) {
        let first_unlock = (vesting.start_time as u128) + (vesting.iteration_period_ms as u128);
        if (first_unlock > (18446744073709551615u128)) {
            return option::none()
        };
        return option::some((first_unlock as u64))
    };

    // Calculate current iteration
    let elapsed = current_time - vesting.start_time;
    let current_iteration = elapsed / vesting.iteration_period_ms;

    // All done?
    if (current_iteration >= vesting.iterations_total) {
        return option::none()
    };

    // Next iteration time (use u128 intermediate to prevent overflow)
    let next_time_u128 =
        (vesting.start_time as u128) + (((current_iteration as u128) + 1) * (vesting.iteration_period_ms as u128));
    if (next_time_u128 > (18446744073709551615u128)) {
        return option::none()
    };
    option::some((next_time_u128 as u64))
}

// === Test Functions ===

#[test_only]
public fun create_vesting_for_testing<CoinType>(
    coin: Coin<CoinType>,
    dao_address: address,
    amount_per_iteration: u64,
    start_time: u64,
    iterations_total: u64,
    iteration_period_ms: u64,
    is_cancellable: bool,
    ctx: &mut TxContext,
): (Vesting<CoinType>, VestingCap) {
    let vesting_uid = object::new(ctx);
    let vesting_id = vesting_uid.to_inner();
    let vesting = Vesting {
        id: vesting_uid,
        dao_address,
        balance: coin.into_balance(),
        coin_type: type_name::get<CoinType>(),
        amount_per_iteration,
        claimed_amount: 0,
        first_unclaimed_iteration: 0,
        partial_claimed_in_iteration: 0,
        start_time,
        iterations_total,
        iteration_period_ms,
        is_cancellable,
        metadata: option::none(),
    };
    let cap = VestingCap {
        id: object::new(ctx),
        vesting_id,
        account_id: object::id_from_address(dao_address),
        dao_address,
    };
    (vesting, cap)
}

#[test_only]
/// Insert a registry entry for a vesting, initializing the registry if needed.
/// Mirrors the logic in do_create_vesting without the executable machinery.
public fun add_registry_entry_for_testing<CoinType>(
    account: &mut Account,
    registry: &PackageRegistry,
    vesting_id: ID,
    is_cancellable: bool,
) {
    if (!account.has_managed_data(VestingRegistryKey {})) {
        account.add_managed_data_with_package_witness(
            registry,
            VestingRegistryKey {},
            VestingRegistry { entries: vec_map::empty() },
            version::current(),
        );
    };
    let registry_mut: &mut VestingRegistry =
        account.borrow_managed_data_mut_with_package_witness(
            registry,
            VestingRegistryKey {},
            version::current(),
        );
    registry_mut.entries.insert(vesting_id, VestingEntry {
        coin_type: type_name::get<CoinType>(),
        is_cancellable,
    });
}
