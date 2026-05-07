#[test_only]
module account_actions::vault_tests;

use account_actions::vault;
use account_actions::actions_version as version;
use account_protocol::account::{Self, Account};
use account_protocol::metadata;
use account_protocol::deps;
use account_protocol::owned;
use account_protocol::executable_resources;
use account_protocol::intent_interface;
use account_protocol::intents;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageRegistry,
    PackageAdminCap
};
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object::{Self as object, ID};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Macros ===

use fun intent_interface::build_intent as Account.build_intent;

// === Constants ===

const OWNER: address = @0xCAFE;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}
public struct VaultIntent() has copy, drop;
public struct TEST_COIN has drop {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    package_registry::add_for_testing(
        &mut extensions,
        b"AccountActions".to_string(),
        @account_actions,
        1,
    );
    package_registry::add_for_testing(
        &mut extensions,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&extensions, object::id_from_address(@0x0));
    let account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    destroy(cap);
    (scenario, extensions, account, clock)
}

fun end(scenario: Scenario, extensions: PackageRegistry, account: Account, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

/// Helper: open a vault via intent pipeline without approving deposit coin types.
fun open_vault_without_approval(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"open_vault".to_string();
    let params = intents::new_params(
        key, b"Open vault".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let action_data = bcs::to_bytes(&vault_name);
            intents::add_typed_action(intent, vault::vault_open_marker(), action_data, iw);
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    vault::do_init_open<Config, Outcome, VaultIntent>(
        &mut executable, account, extensions, VaultIntent(), ctx,
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Helper: open a vault and approve SUI deposits via intent pipeline.
fun open_vault(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"open_vault".to_string();
    let params = intents::new_params(
        key, b"Open vault".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let action_data = bcs::to_bytes(&vault_name);
            intents::add_typed_action(intent, vault::vault_open_marker(), action_data, iw);

            let approve_action_data = bcs::to_bytes(&vault_name);
            intents::add_typed_action(
                intent,
                vault::vault_approve_coin_type_marker<SUI>(),
                approve_action_data,
                iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    vault::do_init_open<Config, Outcome, VaultIntent>(
        &mut executable, account, extensions, VaultIntent(), ctx,
    );
    vault::do_approve_coin_type<Config, Outcome, SUI, VaultIntent>(
        &mut executable, account, extensions, VaultIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Helper: deposit a coin into a vault via intent pipeline (external deposit).
fun deposit_to_vault(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"deposit".to_string();
    let params = intents::new_params(
        key, b"Deposit".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            // BCS: vault_name (vec<u8>) + expected_amount (u64)
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&amount));
            intents::add_typed_action(
                intent,
                vault::vault_deposit_external_marker<SUI>(),
                action_data,
                iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    let coin = coin::mint_for_testing<SUI>(amount, ctx);
    vault::do_deposit_external<Config, Outcome, SUI, VaultIntent>(
        &mut executable, account, extensions, coin, VaultIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Helper: create a stream via intent pipeline.
/// Returns stream_id. StreamCap is transferred to beneficiary (take with scenario.next_tx + take_from_address).
fun create_stream_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    beneficiary: address,
    amount_per_iteration: u64,
    start_time: Option<u64>,
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let key = b"create_stream".to_string();
    let params = intents::new_params(
        key, b"Create stream".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&beneficiary));
            action_data.append(bcs::to_bytes(&amount_per_iteration));

            if (start_time.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(start_time.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
            };

            action_data.append(bcs::to_bytes(&iterations_total));
            action_data.append(bcs::to_bytes(&iteration_period_ms));

            if (claim_window_ms.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(claim_window_ms.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
            };

            // expiry_ms = None for regular streams
            action_data.append(bcs::to_bytes(&false));
            // whitelisted_recipients = empty for regular streams
            let empty_recipients = vector::empty<address>();
            action_data.append(bcs::to_bytes(&empty_recipients));

            intents::add_typed_action(
                intent, vault::create_stream_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    let stream_id = vault::do_init_create_stream<Config, Outcome, SUI, VaultIntent>(
        &mut executable, account, extensions, clock, VaultIntent(), ctx,
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
    stream_id
}

/// Helper: collect from a stream via intent pipeline.
/// Returns the collected coin from executable_resources.
fun collect_stream_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    stream_id: ID,
    cap: vault::StreamCap,
    amount: u64,
    resource_name: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): (coin::Coin<SUI>, vault::StreamCap) {
    let cap_resource_name = b"stream_cap";
    let key = b"collect_stream".to_string();
    let params = intents::new_params(
        key, b"Collect stream".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            let stream_addr = stream_id.to_address();
            action_data.append(bcs::to_bytes(&stream_addr));
            action_data.append(bcs::to_bytes(&resource_name));
            action_data.append(bcs::to_bytes(&amount));
            action_data.append(bcs::to_bytes(&cap_resource_name));
            intents::add_typed_action(
                intent, vault::collect_stream_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    executable_resources::provide_object_for_testing<vault::StreamCap, Outcome>(
        &mut executable, cap_resource_name.to_string(), cap, ctx,
    );
    vault::do_collect_stream<Config, Outcome, SUI, VaultIntent>(
        &mut executable, account, extensions, clock, VaultIntent(), ctx,
    );
    let collected = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, resource_name.to_string(),
    );
    let cap = executable_resources::take_object_for_testing<vault::StreamCap, Outcome>(
        &mut executable, cap_resource_name.to_string(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
    (collected, cap)
}

/// Helper: cancel a stream via intent pipeline.
/// Cancel only removes stream metadata; it does not move funds.
fun cancel_stream_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    stream_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"cancel_stream".to_string();
    let params = intents::new_params(
        key, b"Cancel stream".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            let stream_addr = stream_id.to_address();
            action_data.append(bcs::to_bytes(&stream_addr));
            intents::add_typed_action(
                intent, vault::cancel_stream_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    vault::do_cancel_stream<Config, Outcome, SUI, VaultIntent>(
        &mut executable, account, extensions, clock, VaultIntent(), ctx,
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

fun close_vault_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"close_vault".to_string();
    let params = intents::new_params(
        key, b"Close vault".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let action_data = bcs::to_bytes(&vault_name);
            intents::add_typed_action(intent, vault::vault_close_marker(), action_data, iw);
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    vault::do_init_close<Config, Outcome, VaultIntent>(
        &mut executable, account, extensions, VaultIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

// === Tests ===

#[test]
fun test_open_close_vault() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    assert!(vault::has_vault(&account, vault_name.to_string()));

    close_vault_via_intent(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    assert!(!vault::has_vault(&account, vault_name.to_string()));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_withdraw_with_admin_cap_removes_last_balance_entry() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"admin_cap_vault";

    vault::open_vault_for_testing(
        &mut account,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    vault::deposit_for_testing<SUI>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        coin::mint_for_testing<SUI>(250, scenario.ctx()),
    );
    let cap = vault::create_vault_admin_cap_for_testing(
        vault_name.to_string(),
        object::id(&account),
        scenario.ctx(),
    );

    let withdrawn = vault::withdraw_with_admin_cap<Config, SUI>(
        &mut account,
        &extensions,
        &cap,
        250,
        scenario.ctx(),
    );

    assert!(withdrawn.value() == 250);
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(!vault::coin_type_exists<SUI>(vault_ref));

    destroy(withdrawn);
    vault::destroy_vault_admin_cap(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EAdminCapAccountMismatch, location = account_actions::vault)]
fun test_withdraw_with_admin_cap_rejects_wrong_account() {
    let (mut scenario, extensions, mut account_a, clock) = start();
    let vault_name = b"admin_cap_vault";

    let deps_b = deps::new_for_testing(&extensions, object::id_from_address(@0x0));
    let mut account_b = account::new(
        Config {},
        metadata::empty(),
        deps_b,
        Witness(),
        scenario.ctx(),
    );

    vault::open_vault_for_testing(
        &mut account_a,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    vault::deposit_for_testing<SUI>(
        &mut account_a,
        &extensions,
        vault_name.to_string(),
        coin::mint_for_testing<SUI>(50, scenario.ctx()),
    );
    let cap = vault::create_vault_admin_cap_for_testing(
        vault_name.to_string(),
        object::id(&account_a),
        scenario.ctx(),
    );

    let withdrawn = vault::withdraw_with_admin_cap<Config, SUI>(
        &mut account_b,
        &extensions,
        &cap,
        10,
        scenario.ctx(),
    );

    destroy(withdrawn);
    vault::destroy_vault_admin_cap(cap);
    destroy(account_b);
    end(scenario, extensions, account_a, clock);
}

#[test]
#[expected_failure(abort_code = vault::EAmountMustBeGreaterThanZero, location = account_actions::vault)]
fun test_withdraw_with_admin_cap_rejects_zero_amount() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"admin_cap_vault";

    vault::open_vault_for_testing(
        &mut account,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    let cap = vault::create_vault_admin_cap_for_testing(
        vault_name.to_string(),
        object::id(&account),
        scenario.ctx(),
    );

    let withdrawn = vault::withdraw_with_admin_cap<Config, SUI>(
        &mut account,
        &extensions,
        &cap,
        0,
        scenario.ctx(),
    );

    destroy(withdrawn);
    vault::destroy_vault_admin_cap(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ECoinTypeDoesNotExist, location = account_actions::vault)]
fun test_withdraw_with_admin_cap_rejects_missing_coin_type() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"admin_cap_vault";

    vault::open_vault_for_testing(
        &mut account,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    let cap = vault::create_vault_admin_cap_for_testing(
        vault_name.to_string(),
        object::id(&account),
        scenario.ctx(),
    );

    let withdrawn = vault::withdraw_with_admin_cap<Config, SUI>(
        &mut account,
        &extensions,
        &cap,
        1,
        scenario.ctx(),
    );

    destroy(withdrawn);
    vault::destroy_vault_admin_cap(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EInsufficientBalance, location = account_actions::vault)]
fun test_withdraw_with_admin_cap_rejects_insufficient_balance() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"admin_cap_vault";

    vault::open_vault_for_testing(
        &mut account,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    vault::deposit_for_testing<SUI>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        coin::mint_for_testing<SUI>(10, scenario.ctx()),
    );
    let cap = vault::create_vault_admin_cap_for_testing(
        vault_name.to_string(),
        object::id(&account),
        scenario.ctx(),
    );

    let withdrawn = vault::withdraw_with_admin_cap<Config, SUI>(
        &mut account,
        &extensions,
        &cap,
        20,
        scenario.ctx(),
    );

    destroy(withdrawn);
    vault::destroy_vault_admin_cap(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_deposit_and_balance() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(vault::coin_type_exists<SUI>(vault_ref));
    assert!(vault::coin_type_value<SUI>(vault_ref) == 1000);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_spend() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    // Spend via intent
    let key = b"spend".to_string();
    let params = intents::new_params(
        key, b"Spend".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            // BCS: vault_name + amount + spend_all + resource_name
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&1000u64));
            action_data.append(bcs::to_bytes(&false));
            action_data.append(bcs::to_bytes(&b"withdrawn"));
            intents::add_typed_action(
                intent, vault::vault_spend_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    vault::do_spend<Config, Outcome, SUI, VaultIntent>(
        &mut executable, &mut account, &extensions, VaultIntent(), scenario.ctx(),
    );

    let withdrawn = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"withdrawn".to_string(),
    );
    assert!(withdrawn.value() == 1000);
    destroy(withdrawn);

    account.confirm_execution(executable);

    // Vault should be empty
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(!vault::coin_type_exists<SUI>(vault_ref));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_spend_all() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 777, &clock, scenario.ctx());

    // Spend all via intent (amount field ignored when spend_all=true)
    let key = b"spend_all".to_string();
    let params = intents::new_params(
        key, b"Spend all".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&0u64)); // amount ignored
            action_data.append(bcs::to_bytes(&true)); // spend_all
            action_data.append(bcs::to_bytes(&b"all_funds"));
            intents::add_typed_action(
                intent, vault::vault_spend_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    vault::do_spend<Config, Outcome, SUI, VaultIntent>(
        &mut executable, &mut account, &extensions, VaultIntent(), scenario.ctx(),
    );

    let withdrawn = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"all_funds".to_string(),
    );
    assert!(withdrawn.value() == 777);
    destroy(withdrawn);
    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_spend_all_after_balance_entry_purged_returns_zero_coin() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 777, &clock, scenario.ctx());

    let first_key = b"spend_all_once".to_string();
    let first_params = intents::new_params(
        first_key, b"Spend all once".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, first_params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&0u64));
            action_data.append(bcs::to_bytes(&true));
            action_data.append(bcs::to_bytes(&b"all_funds_once"));
            intents::add_typed_action(
                intent, vault::vault_spend_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut first_executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, first_key, &clock, Witness(), scenario.ctx(),
    );
    vault::do_spend<Config, Outcome, SUI, VaultIntent>(
        &mut first_executable, &mut account, &extensions, VaultIntent(), scenario.ctx(),
    );

    let first_withdrawn = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut first_executable, b"all_funds_once".to_string(),
    );
    assert!(first_withdrawn.value() == 777);
    destroy(first_withdrawn);
    account.confirm_execution(first_executable);

    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(!vault::coin_type_exists<SUI>(vault_ref));

    let second_key = b"spend_all_twice".to_string();
    let second_params = intents::new_params(
        second_key, b"Spend all twice".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, second_params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&0u64));
            action_data.append(bcs::to_bytes(&true));
            action_data.append(bcs::to_bytes(&b"all_funds_twice"));
            intents::add_typed_action(
                intent, vault::vault_spend_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut second_executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, second_key, &clock, Witness(), scenario.ctx(),
    );
    vault::do_spend<Config, Outcome, SUI, VaultIntent>(
        &mut second_executable, &mut account, &extensions, VaultIntent(), scenario.ctx(),
    );

    let second_withdrawn = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut second_executable, b"all_funds_twice".to_string(),
    );
    assert!(second_withdrawn.value() == 0);
    destroy(second_withdrawn);
    account.confirm_execution(second_executable);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_deposit_approved_permissionless() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"donations";

    open_vault_without_approval(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    // donations* vaults accept permissionless deposits without a coin approval.
    let coin = coin::mint_for_testing<SUI>(500, scenario.ctx());
    vault::deposit_approved<Config, SUI>(&mut account, &extensions, vault_name.to_string(), coin);

    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(vault::coin_type_exists<SUI>(vault_ref));
    assert!(vault::coin_type_value<SUI>(vault_ref) == 500);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ECoinTypeNotApproved, location = account_actions::vault)]
fun test_deposit_rejects_unapproved_non_sui_non_donations_vault() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"treasury";

    open_vault_without_approval(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let coin = coin::mint_for_testing<TEST_COIN>(500, scenario.ctx());
    vault::deposit_approved<Config, TEST_COIN>(&mut account, &extensions, vault_name.to_string(), coin);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_open_vault_approves_sui_by_default() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"treasury";

    open_vault_without_approval(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(500, scenario.ctx());
    vault::deposit_approved<Config, SUI>(&mut account, &extensions, vault_name.to_string(), coin);
    assert!(vault::balance<Config, SUI>(&account, &extensions, vault_name.to_string()) == 500);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_deposits() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 100, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 200, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 300, &clock, scenario.ctx());

    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(vault::coin_type_value<SUI>(vault_ref) == 600);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_deposit_to_treasury_allowed() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"treasury";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(500, scenario.ctx());
    vault::deposit_approved<Config, SUI>(&mut account, &extensions, vault_name.to_string(), coin);
    assert!(vault::balance<Config, SUI>(&account, &extensions, vault_name.to_string()) == 500);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_multiple_deposits_approved() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"donations";

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let coin1 = coin::mint_for_testing<SUI>(100, scenario.ctx());
    vault::deposit_approved<Config, SUI>(&mut account, &extensions, vault_name.to_string(), coin1);

    let coin2 = coin::mint_for_testing<SUI>(200, scenario.ctx());
    vault::deposit_approved<Config, SUI>(&mut account, &extensions, vault_name.to_string(), coin2);

    let coin3 = coin::mint_for_testing<SUI>(300, scenario.ctx());
    vault::deposit_approved<Config, SUI>(&mut account, &extensions, vault_name.to_string(), coin3);

    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(vault::coin_type_value<SUI>(vault_ref) == 600);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_create_and_collect_from_stream() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(clock.timestamp_ms()),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(vault::has_stream(&account, &extensions, vault_name.to_string(), stream_id));

    // Get StreamCap from beneficiary
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);

    clock.increment_for_testing(50_000);
    let claimable = vault::calculate_claimable<Config>(
        &account,
        &extensions,
        vault_name.to_string(),
        stream_id,
        &clock,
    );
    assert!(claimable == 500);

    // Collect via intent
    let (collected, cap) = collect_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        cap,
        500,
        b"collected",
        &clock,
        scenario.ctx(),
    );
    assert!(collected.value() == 500);

    let (_, claimed, _, _, _) = vault::stream_info<Config>(
        &account,
        &extensions,
        vault_name.to_string(),
        stream_id,
    );
    assert!(claimed == 500);

    let claimable_after = vault::calculate_claimable<Config>(
        &account,
        &extensions,
        vault_name.to_string(),
        stream_id,
        &clock,
    );
    assert!(claimable_after == 0);

    destroy(collected);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_create_stream_with_none_start_time() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    // Set clock to a non-zero time to verify it's actually used
    clock.increment_for_testing(5_000);

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    // Pass option::none() for start_time — should use clock time (5000)
    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::none(),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    assert!(vault::has_stream(&account, &extensions, vault_name.to_string(), stream_id));

    // Advance 1 iteration and verify claimable
    clock.increment_for_testing(10_000);
    let claimable = vault::calculate_claimable<Config>(
        &account,
        &extensions,
        vault_name.to_string(),
        stream_id,
        &clock,
    );
    assert!(claimable == 100);

    // Collect to confirm it works end-to-end
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);

    let (collected, cap) = collect_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        cap,
        100,
        b"collected",
        &clock,
        scenario.ctx(),
    );
    assert!(collected.value() == 100);

    destroy(collected);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EStreamNotStarted)]
fun test_collect_before_start() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(clock.timestamp_ms() + 10_000),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);

    // Attempt collect before start — should fail
    let (collected, cap) = collect_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        cap,
        100,
        b"collected",
        &clock,
        scenario.ctx(),
    );

    destroy(collected);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EStreamCapMismatch, location = account_actions::vault)]
fun test_collect_stream_cap_account_mismatch() {
    let (mut scenario, extensions, mut account_a, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    let deps_b = deps::new_for_testing(&extensions, object::id_from_address(@0x0));
    let mut account_b = account::new(
        Config {},
        metadata::empty(),
        deps_b,
        Witness(),
        scenario.ctx(),
    );

    open_vault(&mut account_a, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account_a, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account_a,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(clock.timestamp_ms()),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    clock.increment_for_testing(50_000);

    // Cap was minted for account_a; using it against account_b must fail.
    let (collected, cap) = collect_stream_via_intent(
        &mut account_b,
        &extensions,
        vault_name,
        stream_id,
        cap,
        100,
        b"collected",
        &clock,
        scenario.ctx(),
    );

    destroy(collected);
    destroy(cap);
    end(scenario, extensions, account_a, clock);
    destroy(account_b);
}

#[test]
fun test_collect_stream_direct_full_retirement_allows_destroy_cap_and_close_vault() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"stream_vault";
    let beneficiary = @0xBEEF;

    vault::open_vault_for_testing(
        &mut account,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    vault::deposit_for_testing<SUI>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        coin::mint_for_testing<SUI>(500, scenario.ctx()),
    );

    let stream_id = vault::create_stream_internal<Config, SUI>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        beneficiary,
        100,
        clock.timestamp_ms(),
        5,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    clock.increment_for_testing(50_000);

    let collected = vault::collect_stream<Config, SUI>(
        &mut account,
        &extensions,
        &cap,
        0,
        &clock,
        scenario.ctx(),
    );

    assert!(collected.value() == 500);
    assert!(!vault::has_stream(&account, &extensions, vault_name.to_string(), stream_id));
    vault::destroy_stream_cap(cap, &account, &extensions);
    destroy(collected);

    scenario.next_tx(OWNER);
    close_vault_via_intent(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    assert!(!vault::has_vault(&account, vault_name.to_string()));

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EStreamCapMismatch, location = account_actions::vault)]
fun test_collect_stream_direct_rejects_mismatched_stream_cap() {
    let (mut scenario, extensions, mut account_a, mut clock) = start();
    let vault_name = b"stream_vault";
    let beneficiary = @0xBEEF;

    let deps_b = deps::new_for_testing(&extensions, object::id_from_address(@0x0));
    let mut account_b = account::new(
        Config {},
        metadata::empty(),
        deps_b,
        Witness(),
        scenario.ctx(),
    );

    vault::open_vault_for_testing(
        &mut account_a,
        &extensions,
        vault_name.to_string(),
        scenario.ctx(),
    );
    vault::deposit_for_testing<SUI>(
        &mut account_a,
        &extensions,
        vault_name.to_string(),
        coin::mint_for_testing<SUI>(100, scenario.ctx()),
    );
    let _stream_id = vault::create_stream_internal<Config, SUI>(
        &mut account_a,
        &extensions,
        vault_name.to_string(),
        beneficiary,
        100,
        clock.timestamp_ms(),
        1,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    clock.increment_for_testing(10_000);

    let collected = vault::collect_stream<Config, SUI>(
        &mut account_b,
        &extensions,
        &cap,
        0,
        &clock,
        scenario.ctx(),
    );

    destroy(collected);
    destroy(cap);
    destroy(account_b);
    end(scenario, extensions, account_a, clock);
}

#[test]
fun test_cancel_stream() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(clock.timestamp_ms()),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    // Get StreamCap from beneficiary
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);

    clock.increment_for_testing(30_000);

    // Cancel stream — stream metadata removed, funds remain in vault.
    cancel_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        &clock,
        scenario.ctx(),
    );
    assert!(!vault::has_stream(&account, &extensions, vault_name.to_string(), stream_id));
    assert!(vault::get_total_balance<Config, SUI>(&account, &extensions) == 1000);

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = 1, location = account_protocol::executable_resources)]
fun test_cancel_then_deposit_from_resources_fails() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(clock.timestamp_ms()),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    clock.increment_for_testing(30_000);

    let key = b"cancel_then_deposit".to_string();
    let params = intents::new_params(
        key, b"Cancel then deposit".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            let mut cancel_action_data = bcs::to_bytes(&vault_name);
            let stream_addr = stream_id.to_address();
            cancel_action_data.append(bcs::to_bytes(&stream_addr));
            intents::add_typed_action(
                intent, vault::cancel_stream_marker<SUI>(), cancel_action_data, iw,
            );

            let mut deposit_action_data = bcs::to_bytes(&vault_name);
            deposit_action_data.append(bcs::to_bytes(&b"stream_refund"));
            intents::add_typed_action(
                intent,
                vault::vault_deposit_from_resources_marker<SUI>(),
                deposit_action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );

    vault::do_cancel_stream<Config, Outcome, SUI, VaultIntent>(
        &mut executable,
        &mut account,
        &extensions,
        &clock,
        VaultIntent(),
        scenario.ctx(),
    );

    // Cancel no longer emits coin resources. Deposit-from-resources must fail.
    vault::do_init_deposit_from_resources<Config, Outcome, SUI, VaultIntent>(
        &mut executable,
        &mut account,
        &extensions,
        VaultIntent(),
    );

    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), scenario.ctx()));

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_withdraw_object_then_deposit_object_from_resources() {
    let (mut scenario, mut extensions, mut account, clock) = start();
    let vault_name = b"recovery_vault";
    let resource_name = b"coin_object";
    let amount = 321u64;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(amount, scenario.ctx());
    let coin_id = object::id(&coin);
    sui::transfer::public_transfer(coin, object::id_to_address(&object::id(&account)));
    scenario.next_tx(OWNER);

    let key = b"recover_coin_object".to_string();
    let params = intents::new_params(
        key, b"Recover coin object".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            let mut withdraw_action_data = bcs::to_bytes(&coin_id);
            withdraw_action_data.append(bcs::to_bytes(&resource_name));
            intents::add_action_spec(
                intent,
                owned::owned_withdraw_object<Coin<SUI>>(),
                withdraw_action_data,
                copy iw,
            );

            let mut deposit_action_data = bcs::to_bytes(&vault_name);
            deposit_action_data.append(bcs::to_bytes(&resource_name));
            intents::add_action_spec(
                intent,
                vault::vault_deposit_object_from_resources_marker<SUI>(),
                deposit_action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    let account_id = object::id(&account);
    let receiving = ts::most_recent_receiving_ticket<Coin<SUI>>(&account_id);

    owned::do_withdraw_object<Outcome, Coin<SUI>, VaultIntent>(
        &mut executable,
        &mut account,
        &extensions,
        receiving,
        VaultIntent(),
        scenario.ctx(),
    );
    vault::do_init_deposit_object_from_resources<Config, Outcome, SUI, VaultIntent>(
        &mut executable,
        &mut account,
        &extensions,
        VaultIntent(),
    );

    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), scenario.ctx()));

    assert!(vault::balance<Config, SUI>(&account, &extensions, vault_name.to_string()) == amount);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_stream_info() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;
    let start_time = 5_000;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(start_time),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    let (
        info_amount,
        info_claimed,
        info_start,
        info_iterations,
        info_period,
    ) = vault::stream_info<Config>(&account, &extensions, vault_name.to_string(), stream_id);

    assert!(info_amount == 100);
    assert!(info_claimed == 0);
    assert!(info_start == start_time);
    assert!(info_iterations == 10);
    assert!(info_period == 10_000);

    // Clean up StreamCap
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    destroy(cap);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_stream_next_vest_time() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let start_time = clock.timestamp_ms() + 5_000;
    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(start_time),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    // Before start: first unlock is at start_time + iteration_period (not start_time itself)
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    let next = vault::stream_next_vest_time(vault_ref, stream_id, &clock);
    assert!(next.is_some());
    assert!(*next.borrow() == start_time + 10_000);

    clock.increment_for_testing(5_000);
    // At start_time exactly: 0 iterations completed, next unlock at start_time + iteration_period
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    let next = vault::stream_next_vest_time(vault_ref, stream_id, &clock);
    assert!(next.is_some());
    assert!(*next.borrow() == start_time + 10_000);

    clock.increment_for_testing(100_000);
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    let next = vault::stream_next_vest_time(vault_ref, stream_id, &clock);
    assert!(next.is_none());

    // Clean up StreamCap
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    destroy(cap);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_stream_claimable_now() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"test_vault";
    let beneficiary = @0xBEEF;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 1000, &clock, scenario.ctx());

    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        100,
        option::some(clock.timestamp_ms()),
        10,
        10_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    let claimable = vault::stream_claimable_now(vault_ref, stream_id, &clock);
    assert!(claimable == 0);

    clock.increment_for_testing(10_000);
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    let claimable = vault::stream_claimable_now(vault_ref, stream_id, &clock);
    assert!(claimable == 100);

    clock.increment_for_testing(40_000);
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    let claimable = vault::stream_claimable_now(vault_ref, stream_id, &clock);
    assert!(claimable == 500);

    // Clean up StreamCap
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);
    destroy(cap);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_get_total_balance_returns_raw_balance() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"treasury";
    let beneficiary = OWNER;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 100, &clock, scenario.ctx());

    let start_time = clock.timestamp_ms() + 10_000;
    let stream_id = create_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        beneficiary,
        10,
        option::some(start_time),
        3,
        1_000,
        option::none(),
        &clock,
        scenario.ctx(),
    );

    // get_total_balance returns raw balance (streams race-condition on funds)
    assert!(vault::get_total_balance<Config, SUI>(&account, &extensions) == 100);

    // Get StreamCap
    scenario.next_tx(beneficiary);
    let cap = scenario.take_from_address<vault::StreamCap>(beneficiary);

    cancel_stream_via_intent(
        &mut account,
        &extensions,
        vault_name,
        stream_id,
        &clock,
        scenario.ctx(),
    );

    // Cancel does not move funds; raw balance remains unchanged.
    assert!(vault::get_total_balance<Config, SUI>(&account, &extensions) == 100);

    destroy(cap);
    end(scenario, extensions, account, clock);
}

// === Bug 3 regression: assert_action_type rejects wrong type ===

#[test]
#[expected_failure(abort_code = 0, location = account_protocol::action_validation)]
/// Verify that do_spend aborts when the ActionSpec type is VaultOpen instead of VaultSpend.
/// Regression test for Bug 3: missing assert_action_type before BCS deserialization.
fun test_spend_aborts_on_wrong_action_type() {
    let (mut scenario, extensions, mut account, clock) = start();

    let vault_name = b"treasury";
    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    // Build an intent with VaultOpen action spec (wrong type for do_spend)
    let key = b"wrong_type_spend".to_string();
    let params = intents::new_params(
        key, b"Wrong type".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            // Use VaultOpen BCS format (just vault_name) but tag it as VaultOpen type
            let action_data = bcs::to_bytes(&vault_name);
            intents::add_typed_action(intent, vault::vault_open_marker(), action_data, iw);
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );

    // This should abort with EWrongActionType (0) at action_validation
    vault::do_spend<Config, Outcome, SUI, VaultIntent>(
        &mut executable, &mut account, &extensions, VaultIntent(), scenario.ctx(),
    );

    abort 42
}

// === Spending Limit Tests ===

/// Helper: create a spending limit via intent pipeline (CreateStream with whitelist).
/// Returns spending_limit_id. SpendingCap is transferred to delegate.
fun create_spending_limit_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    vault_name: vector<u8>,
    delegate: address,
    amount_per_iteration: u64,
    start_time: Option<u64>,
    iterations_total: u64,
    iteration_period_ms: u64,
    claim_window_ms: Option<u64>,
    expiry_ms: Option<u64>,
    whitelisted_recipients: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let key = b"create_spending_limit".to_string();
    let params = intents::new_params(
        key, b"Create spending limit".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), VaultIntent(), ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&delegate));
            action_data.append(bcs::to_bytes(&amount_per_iteration));

            if (start_time.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(start_time.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
            };

            action_data.append(bcs::to_bytes(&iterations_total));
            action_data.append(bcs::to_bytes(&iteration_period_ms));

            if (claim_window_ms.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(claim_window_ms.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
            };

            if (expiry_ms.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(expiry_ms.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
            };

            action_data.append(bcs::to_bytes(&whitelisted_recipients));

            intents::add_typed_action(
                intent, vault::create_stream_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    let sl_id = vault::do_init_create_stream<Config, Outcome, SUI, VaultIntent>(
        &mut executable, account, extensions, clock, VaultIntent(), ctx,
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
    sl_id
}

#[test]
#[expected_failure(abort_code = vault::EExpiryNotSupportedForStream, location = account_actions::vault)]
fun test_create_regular_stream_rejects_expiry_at_execution() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let beneficiary = @0xBEEF;
    let expiry = clock.timestamp_ms() + 100_000;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let key = b"create_stream_with_expiry".to_string();
    let params = intents::new_params(
        key, b"Create invalid stream".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), VaultIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&vault_name);
            action_data.append(bcs::to_bytes(&beneficiary));
            action_data.append(bcs::to_bytes(&1000u64));
            action_data.append(bcs::to_bytes(&false)); // start_time = None
            action_data.append(bcs::to_bytes(&10u64));
            action_data.append(bcs::to_bytes(&10_000u64));
            action_data.append(bcs::to_bytes(&false)); // claim_window_ms = None
            action_data.append(bcs::to_bytes(&true)); // expiry_ms = Some(expiry)
            action_data.append(bcs::to_bytes(&expiry));
            let empty_recipients = vector::empty<address>();
            action_data.append(bcs::to_bytes(&empty_recipients));

            intents::add_typed_action(
                intent, vault::create_stream_marker<SUI>(), action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );

    let _stream_id = vault::do_init_create_stream<Config, Outcome, SUI, VaultIntent>(
        &mut executable, &mut account, &extensions, &clock, VaultIntent(), scenario.ctx(),
    );
    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EZeroWhitelistRecipient, location = account_actions::vault)]
fun test_create_spending_limit_rejects_zero_whitelist_recipient_at_execution() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[@0x0],
        &clock, scenario.ctx(),
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ETooManyRecipients, location = account_actions::vault)]
fun test_create_spending_limit_rejects_too_many_recipients_at_execution() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let mut recipients = vector::empty<address>();
    let mut i = 1;
    while (i <= 101) {
        recipients.push_back(sui::address::from_u256((i as u256)));
        i = i + 1;
    };

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), recipients,
        &clock, scenario.ctx(),
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EDuplicateWhitelistRecipient, location = account_actions::vault)]
fun test_create_spending_limit_rejects_duplicate_recipients_at_execution() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());

    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[vendor, vendor],
        &clock, scenario.ctx(),
    );

    end(scenario, extensions, account, clock);
}

#[test]
fun test_create_and_spend_with_cap() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor_a = @0xAAAA;
    let vendor_b = @0xBBBB;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let sl_id = create_spending_limit_via_intent(
        &mut account,
        &extensions,
        vault_name,
        delegate,
        1000, // 1000 per iteration
        option::some(clock.timestamp_ms()),
        10,   // 10 iterations
        10_000, // 10s per iteration
        option::none(),
        option::none(),
        vector[vendor_a, vendor_b],
        &clock,
        scenario.ctx(),
    );

    assert!(vault::has_stream(&account, &extensions, vault_name.to_string(), sl_id));

    // Get SpendingCap from delegate
    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);

    // Advance 3 iterations (30s) → 3000 available
    clock.increment_for_testing(30_000);

    let available = vault::spending_limit_available<Config>(
        &account, &extensions, vault_name.to_string(), sl_id, &clock,
    );
    assert!(available == 3000);

    // Spend 500 to vendor_a
    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor_a, 500, &clock, scenario.ctx(),
    );

    // Check remaining budget
    let available_after = vault::spending_limit_available<Config>(
        &account, &extensions, vault_name.to_string(), sl_id, &clock,
    );
    assert!(available_after == 2500);

    // Spend 1000 to vendor_b
    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor_b, 1000, &clock, scenario.ctx(),
    );

    let available_after2 = vault::spending_limit_available<Config>(
        &account, &extensions, vault_name.to_string(), sl_id, &clock,
    );
    assert!(available_after2 == 1500);

    // Vault balance should be reduced
    let vault_ref = vault::borrow_vault(&account, &extensions, vault_name.to_string());
    assert!(vault::coin_type_value<SUI>(vault_ref) == 8500);

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ERecipientNotWhitelisted, location = account_actions::vault)]
fun test_spend_with_cap_rejects_non_whitelisted_recipient() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor_a = @0xAAAA;
    let bad_recipient = @0xBAD;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[vendor_a],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);
    clock.increment_for_testing(10_000);

    // Try to spend to non-whitelisted recipient — should fail
    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, bad_recipient, 500, &clock, scenario.ctx(),
    );

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::EInsufficientSpendingBudget, location = account_actions::vault)]
fun test_spend_with_cap_rejects_over_budget() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);
    clock.increment_for_testing(20_000); // 2 iterations → 2000 available

    // Try to spend 3000 (only 2000 available) — should fail
    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor, 3000, &clock, scenario.ctx(),
    );

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitExpired, location = account_actions::vault)]
fun test_spend_with_cap_rejects_expired() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let expiry = clock.timestamp_ms() + 50_000;
    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::some(expiry), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);

    // Advance past expiry
    clock.increment_for_testing(60_000);

    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor, 500, &clock, scenario.ctx(),
    );

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitExpired, location = account_actions::vault)]
fun test_spend_with_cap_rejects_at_expiry() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let expiry = clock.timestamp_ms() + 50_000;
    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::some(expiry), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);

    clock.increment_for_testing(50_000);

    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor, 500, &clock, scenario.ctx(),
    );

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_spending_limit_available_zero_at_expiry() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let expiry = clock.timestamp_ms() + 50_000;
    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::some(expiry), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);

    clock.increment_for_testing(50_000);
    let available = vault::spending_limit_available<Config>(
        &account, &extensions, vault_name.to_string(), sl_id, &clock,
    );
    assert!(available == 0);

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitExpired, location = account_actions::vault)]
fun test_create_spending_limit_rejects_expiry_before_first_unlock() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let start_time = clock.timestamp_ms() + 100_000;
    let iteration_period_ms = 10_000;
    let expiry = start_time + 5_000;

    let _sl_id = create_spending_limit_via_intent(
        &mut account,
        &extensions,
        vault_name,
        delegate,
        1000,
        option::some(start_time),
        10,
        iteration_period_ms,
        option::none(),
        option::some(expiry),
        vector[vendor],
        &clock,
        scenario.ctx(),
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitExpired, location = account_actions::vault)]
fun test_create_spending_limit_rejects_expiry_at_first_unlock() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let start_time = clock.timestamp_ms() + 100_000;
    let iteration_period_ms = 10_000;
    let expiry = start_time + iteration_period_ms;

    let _sl_id = create_spending_limit_via_intent(
        &mut account,
        &extensions,
        vault_name,
        delegate,
        1000,
        option::some(start_time),
        10,
        iteration_period_ms,
        option::none(),
        option::some(expiry),
        vector[vendor],
        &clock,
        scenario.ctx(),
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitNotStarted, location = account_actions::vault)]
fun test_spend_with_cap_rejects_before_start() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let _sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms() + 100_000), 10, 10_000,
        option::none(), option::none(), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);

    // Try to spend before start time — should fail
    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor, 500, &clock, scenario.ctx(),
    );

    destroy(cap);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_cancel_spending_limit_and_destroy_cap() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);
    clock.increment_for_testing(10_000);

    // Cancel via CancelStream (works for both streams and spending limits)
    cancel_stream_via_intent(
        &mut account, &extensions, vault_name, sl_id, &clock, scenario.ctx(),
    );

    assert!(!vault::has_stream(&account, &extensions, vault_name.to_string(), sl_id));

    // Destroy the now-orphaned SpendingCap
    vault::destroy_spending_cap(cap, &account, &extensions);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_spending_limit_fully_consumed_auto_removes() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 500, &clock, scenario.ctx());

    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        100, option::some(clock.timestamp_ms()), 5, 10_000,
        option::none(), option::none(), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);

    // Advance past all iterations
    clock.increment_for_testing(50_000);

    // Spend entire budget
    vault::spend_with_cap<Config, SUI>(
        &mut account, &extensions, &cap, vendor, 500, &clock, scenario.ctx(),
    );

    // Spending limit should be auto-removed
    assert!(!vault::has_stream(&account, &extensions, vault_name.to_string(), sl_id));

    // Can destroy cap now
    vault::destroy_spending_cap(cap, &account, &extensions);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_cleanup_expired_spending_limit_removes_entry_and_allows_cap_destroy() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let expiry = clock.timestamp_ms() + 50_000;
    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::some(expiry), vector[vendor],
        &clock, scenario.ctx(),
    );

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);
    clock.increment_for_testing(50_000);

    vault::cleanup_expired_spending_limit<Config>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        sl_id,
        &clock,
    );

    assert!(!vault::has_stream(&account, &extensions, vault_name.to_string(), sl_id));
    vault::destroy_spending_cap(cap, &account, &extensions);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitNotExpired, location = account_actions::vault)]
fun test_cleanup_spending_limit_before_expiry_rejected() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let expiry = clock.timestamp_ms() + 50_000;
    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::some(expiry), vector[vendor],
        &clock, scenario.ctx(),
    );

    vault::cleanup_expired_spending_limit<Config>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        sl_id,
        &clock,
    );

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = vault::ESpendingLimitNoExpiry, location = account_actions::vault)]
fun test_cleanup_spending_limit_without_expiry_rejected() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor = @0xAAAA;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[vendor],
        &clock, scenario.ctx(),
    );

    vault::cleanup_expired_spending_limit<Config>(
        &mut account,
        &extensions,
        vault_name.to_string(),
        sl_id,
        &clock,
    );

    end(scenario, extensions, account, clock);
}

#[test]
fun test_spending_limit_recipients_accessor() {
    let (mut scenario, extensions, mut account, clock) = start();
    let vault_name = b"ops_vault";
    let delegate = @0xDE1E;
    let vendor_a = @0xAAAA;
    let vendor_b = @0xBBBB;

    open_vault(&mut account, &extensions, vault_name, &clock, scenario.ctx());
    deposit_to_vault(&mut account, &extensions, vault_name, 10_000, &clock, scenario.ctx());

    let sl_id = create_spending_limit_via_intent(
        &mut account, &extensions, vault_name, delegate,
        1000, option::some(clock.timestamp_ms()), 10, 10_000,
        option::none(), option::none(), vector[vendor_a, vendor_b],
        &clock, scenario.ctx(),
    );

    let recipients = vault::spending_limit_recipients<Config>(
        &account, &extensions, vault_name.to_string(), sl_id,
    );
    assert!(recipients.length() == 2);
    assert!(vector::contains(&recipients, &vendor_a));
    assert!(vector::contains(&recipients, &vendor_b));

    scenario.next_tx(delegate);
    let cap = scenario.take_from_address<vault::SpendingCap>(delegate);
    destroy(cap);
    end(scenario, extensions, account, clock);
}

// === is_donations_vault_name edge cases ===
// Purely lexical; deposit gating depends on it bypassing the approval list,
// so case sensitivity / separators / empty suffix all matter.

#[test]
fun test_is_donations_vault_name_exact_word() {
    assert!(vault::is_donations_vault_name(&b"donations".to_string()));
}

#[test]
fun test_is_donations_vault_name_with_underscore_suffix() {
    assert!(vault::is_donations_vault_name(&b"donations_usdc".to_string()));
}

#[test]
fun test_is_donations_vault_name_with_dash_suffix() {
    assert!(vault::is_donations_vault_name(&b"donations-treasury".to_string()));
}

#[test]
fun test_is_donations_vault_name_rejects_capitalized() {
    assert!(!vault::is_donations_vault_name(&b"Donations".to_string()));
    assert!(!vault::is_donations_vault_name(&b"DONATIONS".to_string()));
    assert!(!vault::is_donations_vault_name(&b"dOnAtIoNs".to_string()));
}

#[test]
fun test_is_donations_vault_name_rejects_prefix_without_separator() {
    // `donationsrugpull` — attacker adds suffix directly without a separator.
    // Must be rejected or the donations carve-out becomes a typo trap.
    assert!(!vault::is_donations_vault_name(&b"donationsrugpull".to_string()));
    assert!(!vault::is_donations_vault_name(&b"donations0".to_string()));
}

#[test]
fun test_is_donations_vault_name_rejects_empty_suffix() {
    // `donations_` and `donations-` — separator present but no actual suffix.
    // The implementation requires len > prefix_len + 1.
    assert!(!vault::is_donations_vault_name(&b"donations_".to_string()));
    assert!(!vault::is_donations_vault_name(&b"donations-".to_string()));
}

#[test]
fun test_is_donations_vault_name_rejects_short_and_empty() {
    assert!(!vault::is_donations_vault_name(&b"".to_string()));
    assert!(!vault::is_donations_vault_name(&b"donation".to_string()));
    assert!(!vault::is_donations_vault_name(&b"donat".to_string()));
}

#[test]
fun test_is_donations_vault_name_rejects_unrelated_prefixes() {
    assert!(!vault::is_donations_vault_name(&b"treasury".to_string()));
    assert!(!vault::is_donations_vault_name(&b"xdonations".to_string()));
    assert!(!vault::is_donations_vault_name(&b" donations".to_string()));
}
