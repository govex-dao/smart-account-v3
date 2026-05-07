#[test_only]
module account_actions::currency_tests;

use account_actions::currency;
use account_actions::transfer as account_transfer;
use account_actions::actions_version as version;
use account_protocol::account::{Self, Account};
use account_protocol::metadata;
use account_protocol::deps;
use account_protocol::executable_resources;
use account_protocol::intent_interface;
use account_protocol::intents;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageRegistry,
    PackageAdminCap
};
use std::option;
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, MetadataCap};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;
use sui::transfer;

// === Macros ===

use fun intent_interface::build_intent as Account.build_intent;

// === Constants ===

const OWNER: address = @0xCAFE;
const RECIPIENT: address = @0xBEEF;

// === Structs ===

public struct Witness() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}
public struct CurrencyIntent() has copy, drop;

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

/// Helper: lock a TreasuryCap with custom permission flags.
fun lock_cap_with_permissions(
    account: &mut Account,
    extensions: &PackageRegistry,
    treasury_cap: TreasuryCap<SUI>,
    max_supply: Option<u64>,
    can_mint: bool,
    can_burn: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"lock_cap".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Lock treasury cap".to_string(),
        vector[0],
        clock.timestamp_ms() + 1_000_000,
        clock,
        ctx,
    );

    account.build_intent!(
        extensions,
        params,
        outcome,
        version::current(),
        CurrencyIntent(),
        ctx,
        |intent, iw| {
            let mut action_data = vector[];
            if (max_supply.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(max_supply.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
                action_data.append(bcs::to_bytes(&0u64));
            };
            action_data.append(bcs::to_bytes(&can_mint));
            action_data.append(bcs::to_bytes(&can_burn));
            action_data.append(bcs::to_bytes(&true)); // can_update_name
            action_data.append(bcs::to_bytes(&true)); // can_update_description
            action_data.append(bcs::to_bytes(&true)); // can_update_icon
            action_data.append(bcs::to_bytes(&b"treasury_cap"));
            intents::add_typed_action(
                intent,
                currency::lock_treasury_cap_marker<SUI>(),
                action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    executable_resources::provide_object_for_testing<TreasuryCap<SUI>, Outcome>(
        &mut executable, b"treasury_cap".to_string(), treasury_cap, ctx,
    );
    currency::do_init_lock_treasury_cap<Config, Outcome, SUI, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Helper: lock a TreasuryCap into the account via the intent pipeline.
fun lock_cap_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    treasury_cap: TreasuryCap<SUI>,
    max_supply: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = b"lock_cap".to_string();
    let outcome = Outcome {};
    let params = intents::new_params(
        key,
        b"Lock treasury cap".to_string(),
        vector[0],
        clock.timestamp_ms() + 1_000_000,
        clock,
        ctx,
    );

    account.build_intent!(
        extensions,
        params,
        outcome,
        version::current(),
        CurrencyIntent(),
        ctx,
        |intent, iw| {
            // BCS: has_max_supply (bool) + max_supply_value (u64) + 5 permission bools
            let mut action_data = vector[];
            if (max_supply.is_some()) {
                action_data.append(bcs::to_bytes(&true));
                action_data.append(bcs::to_bytes(max_supply.borrow()));
            } else {
                action_data.append(bcs::to_bytes(&false));
                action_data.append(bcs::to_bytes(&0u64));
            };
            action_data.append(bcs::to_bytes(&true)); // can_mint
            action_data.append(bcs::to_bytes(&true)); // can_burn
            action_data.append(bcs::to_bytes(&true)); // can_update_name
            action_data.append(bcs::to_bytes(&true)); // can_update_description
            action_data.append(bcs::to_bytes(&true)); // can_update_icon
            action_data.append(bcs::to_bytes(&b"treasury_cap"));
            intents::add_typed_action(
                intent,
                currency::lock_treasury_cap_marker<SUI>(),
                action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    executable_resources::provide_object_for_testing<TreasuryCap<SUI>, Outcome>(
        &mut executable, b"treasury_cap".to_string(), treasury_cap, ctx,
    );
    currency::do_init_lock_treasury_cap<Config, Outcome, SUI, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable);
    // Clean up consumed intent
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

fun mint_admin_cap_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): currency::CurrencyMintAdminCap<SUI> {
    let key = b"mint_admin_cap".to_string();
    let params = intents::new_params(
        key,
        b"Mint currency admin cap".to_string(),
        vector[0],
        clock.timestamp_ms() + 1_000_000,
        clock,
        ctx,
    );

    account.build_intent!(
        extensions,
        params,
        Outcome {},
        version::current(),
        CurrencyIntent(),
        ctx,
        |intent, iw| {
            let action_data = bcs::to_bytes(&b"mint_admin_cap");
            intents::add_typed_action(
                intent,
                currency::mint_currency_admin_cap_marker<SUI>(),
                action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    currency::do_mint_currency_admin_cap<Outcome, SUI, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(), ctx,
    );
    let cap = executable_resources::take_object_for_testing<
        currency::CurrencyMintAdminCap<SUI>,
        Outcome,
    >(&mut executable, b"mint_admin_cap".to_string());
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
    cap
}

// === Tests ===

#[test]
fun test_lock_cap_basic() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::none(), &clock, scenario.ctx(),
    );

    assert!(currency::has_cap<SUI>(&account));
    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(currency::can_mint(rules));
    assert!(currency::can_burn(rules));
    assert!(currency::total_minted(rules) == 0);
    assert!(currency::total_burned(rules) == 0);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_cap_with_max_supply() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::some(1_000_000), &clock, scenario.ctx(),
    );

    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(currency::max_supply(rules) == option::some(1_000_000));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_mint_and_burn_basic() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Setup: lock treasury cap
    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::none(), &clock, scenario.ctx(),
    );

    // Mint via intent
    let key = b"test_mint".to_string();
    let params = intents::new_params(
        key, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"minted_tokens"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );
    let minted_coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"minted_tokens".to_string(),
    );
    assert!(minted_coin.value() == 100);
    account.confirm_execution(executable);

    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(currency::total_minted(rules) == 100);

    // Burn via intent
    let key2 = b"test_burn".to_string();
    let params2 = intents::new_params(
        key2, b"Burn".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params2, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"burn_coin"));
            intents::add_typed_action(intent, currency::currency_burn<SUI>(), action_data, iw);
        },
    );

    let (_, mut executable2) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key2, &clock, Witness(), scenario.ctx(),
    );
    executable_resources::provide_coin_for_testing(
        &mut executable2, b"burn_coin".to_string(), minted_coin, scenario.ctx(),
    );
    currency::do_init_burn<Outcome, SUI, CurrencyIntent>(
        &mut executable2, &mut account, &extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable2);

    let rules2 = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(currency::total_burned(rules2) == 100);

    end(scenario, extensions, account, clock);
}

#[test]
fun test_mint_with_admin_cap() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::none(), &clock, scenario.ctx(),
    );

    let admin_cap = mint_admin_cap_via_intent(&mut account, &extensions, &clock, scenario.ctx());
    let minted_coin = currency::mint_with_admin_cap<SUI>(
        &mut account,
        &extensions,
        &admin_cap,
        123,
        scenario.ctx(),
    );

    assert!(minted_coin.value() == 123);
    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(currency::total_minted(rules) == 123);

    coin::burn_for_testing(minted_coin);
    currency::destroy_currency_mint_admin_cap(admin_cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::ETreasuryCapNotLocked, location = account_actions::currency)]
fun test_mint_admin_cap_requires_locked_treasury_cap() {
    let (mut scenario, extensions, mut account, clock) = start();

    let admin_cap = mint_admin_cap_via_intent(&mut account, &extensions, &clock, scenario.ctx());

    currency::destroy_currency_mint_admin_cap(admin_cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EMintDisabled, location = account_actions::currency)]
fun test_mint_admin_cap_requires_mint_enabled_rules() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_with_permissions(
        &mut account,
        &extensions,
        treasury_cap,
        option::none(),
        false,
        true,
        &clock,
        scenario.ctx(),
    );

    let admin_cap = mint_admin_cap_via_intent(&mut account, &extensions, &clock, scenario.ctx());

    currency::destroy_currency_mint_admin_cap(admin_cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EAdminCapAccountMismatch)]
fun test_mint_with_admin_cap_wrong_account() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::none(), &clock, scenario.ctx(),
    );

    let admin_cap = mint_admin_cap_via_intent(&mut account, &extensions, &clock, scenario.ctx());
    let mut other_account = account::new(
        Config {},
        metadata::empty(),
        deps::new_for_testing(&extensions, object::id_from_address(@0x0)),
        Witness(),
        scenario.ctx(),
    );

    let _coin = currency::mint_with_admin_cap<SUI>(
        &mut other_account,
        &extensions,
        &admin_cap,
        1,
        scenario.ctx(),
    );
    coin::burn_for_testing(_coin);
    destroy(other_account);
    currency::destroy_currency_mint_admin_cap(admin_cap);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EMaxSupply)]
fun test_mint_exceeds_max_supply() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::some(50), &clock, scenario.ctx(),
    );

    // Try to mint 100 (exceeds max supply of 50)
    let key = b"test_max".to_string();
    let params = intents::new_params(
        key, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"minted_coin"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    // Should abort with EMaxSupply
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );

    let coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"minted_coin".to_string(),
    );
    destroy(coin);
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_public_burn() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::none(), &clock, scenario.ctx(),
    );

    // Mint a coin
    let key = b"mint".to_string();
    let params = intents::new_params(
        key, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&200u64);
            action_data.append(bcs::to_bytes(&b"minted_coin"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );
    let coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"minted_coin".to_string(),
    );
    account.confirm_execution(executable);

    // Anyone can burn using public_burn
    currency::public_burn<SUI>(&mut account, &extensions, coin);

    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(currency::total_burned(rules) == 200);

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EWrongValue)]
fun test_burn_wrong_value() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_via_intent(
        &mut account, &extensions, treasury_cap, option::none(), &clock, scenario.ctx(),
    );

    // Mint 100
    let key1 = b"mint".to_string();
    let params1 = intents::new_params(
        key1, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params1, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"minted_coin"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );
    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key1, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut exec1, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );
    let coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut exec1, b"minted_coin".to_string(),
    );
    account.confirm_execution(exec1);

    // Try to burn with wrong amount (50 instead of 100)
    let key2 = b"burn".to_string();
    let params2 = intents::new_params(
        key2, b"Burn".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params2, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&50u64);
            action_data.append(bcs::to_bytes(&b"burn_coin"));
            intents::add_typed_action(intent, currency::currency_burn<SUI>(), action_data, iw);
        },
    );
    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key2, &clock, Witness(), scenario.ctx(),
    );
    executable_resources::provide_coin_for_testing(
        &mut exec2, b"burn_coin".to_string(), coin, scenario.ctx(),
    );
    // Should abort with EWrongValue
    currency::do_init_burn<Outcome, SUI, CurrencyIntent>(
        &mut exec2, &mut account, &extensions, CurrencyIntent(),
    );

    account.confirm_execution(exec2);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EMintDisabled)]
fun test_mint_when_disabled() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_with_permissions(
        &mut account, &extensions, treasury_cap,
        option::none(),
        false, // can_mint = false
        true,  // can_burn
        &clock, scenario.ctx(),
    );

    // Verify rule was set correctly
    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(!currency::can_mint(rules));

    // Try to mint - should abort with EMintDisabled
    let key = b"test_mint_disabled".to_string();
    let params = intents::new_params(
        key, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"minted_coin"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    // Should abort with EMintDisabled
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );

    let coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"minted_coin".to_string(),
    );
    destroy(coin);
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EBurnDisabled)]
fun test_burn_when_disabled() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_with_permissions(
        &mut account, &extensions, treasury_cap,
        option::none(),
        true,  // can_mint (need this to mint first)
        false, // can_burn = false
        &clock, scenario.ctx(),
    );

    // Verify rule was set correctly
    let rules = currency::borrow_rules<SUI>(&account, &extensions);
    assert!(!currency::can_burn(rules));

    // Mint a coin first (minting is allowed)
    let key1 = b"mint_for_burn".to_string();
    let params1 = intents::new_params(
        key1, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params1, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"minted_coin"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );
    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key1, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut exec1, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );
    let coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut exec1, b"minted_coin".to_string(),
    );
    assert!(coin.value() == 100);
    account.confirm_execution(exec1);

    // Try to burn via do_init_burn - should abort with EBurnDisabled
    let key2 = b"test_burn_disabled".to_string();
    let params2 = intents::new_params(
        key2, b"Burn".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params2, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&100u64);
            action_data.append(bcs::to_bytes(&b"burn_coin"));
            intents::add_typed_action(intent, currency::currency_burn<SUI>(), action_data, iw);
        },
    );
    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key2, &clock, Witness(), scenario.ctx(),
    );
    executable_resources::provide_coin_for_testing(
        &mut exec2, b"burn_coin".to_string(), coin, scenario.ctx(),
    );
    // Should abort with EBurnDisabled
    currency::do_init_burn<Outcome, SUI, CurrencyIntent>(
        &mut exec2, &mut account, &extensions, CurrencyIntent(),
    );

    account.confirm_execution(exec2);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::EBurnDisabled)]
fun test_public_burn_when_disabled() {
    let (mut scenario, extensions, mut account, clock) = start();

    let treasury_cap = coin::create_treasury_cap_for_testing<SUI>(scenario.ctx());
    lock_cap_with_permissions(
        &mut account, &extensions, treasury_cap,
        option::none(),
        true,  // can_mint
        false, // can_burn = false
        &clock, scenario.ctx(),
    );

    // Mint a coin
    let key = b"mint".to_string();
    let params = intents::new_params(
        key, b"Mint".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&200u64);
            action_data.append(bcs::to_bytes(&b"minted_coin"));
            intents::add_typed_action(intent, currency::currency_mint<SUI>(), action_data, iw);
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_mint<Outcome, SUI, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );
    let coin = executable_resources::take_coin_for_testing<SUI, Outcome>(
        &mut executable, b"minted_coin".to_string(),
    );
    account.confirm_execution(executable);

    // Should abort with EBurnDisabled via public_burn path
    currency::public_burn<SUI>(&mut account, &extensions, coin);

    end(scenario, extensions, account, clock);
}

// ============================================================
// Cap Ordering Tests
// ============================================================
//
// Tests the new code paths for locking / removing caps in
// different orderings:
// 1. Lock MetadataCap first, then TreasuryCap (update-existing-rules branch)
// 2. Remove MetadataCap while TreasuryCap is present (disable metadata updates)
// 3. Remove both caps (CurrencyRules removed entirely)

/// Test coin type for cap-ordering tests (needs `key` for non-OTW coin_registry::new_currency)
public struct CAP_ORDER_COIN has key { id: UID }

/// Setup with both TreasuryCap and MetadataCap for the same coin type.
fun start_with_both_caps(): (
    Scenario,
    PackageRegistry,
    Account,
    Clock,
    TreasuryCap<CAP_ORDER_COIN>,
    MetadataCap<CAP_ORDER_COIN>,
) {
    // Must start as @0x0 for coin_registry
    let mut scenario = ts::begin(@0x0);
    let mut coin_reg = coin_registry::create_coin_data_registry_for_testing(scenario.ctx());
    let (init, treasury_cap) = coin_registry::new_currency<CAP_ORDER_COIN>(
        &mut coin_reg,
        9,
        b"CAPORD".to_string(),
        b"Cap Order Coin".to_string(),
        b"".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let (currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing(
        init, scenario.ctx(),
    );
    destroy(coin_reg);
    destroy(currency);

    // Switch to OWNER for account setup
    scenario.next_tx(OWNER);
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
    (scenario, extensions, account, clock, treasury_cap, metadata_cap)
}

/// Lock a TreasuryCap<CAP_ORDER_COIN> into the account.
fun lock_treasury(
    account: &mut Account,
    extensions: &PackageRegistry,
    treasury_cap: TreasuryCap<CAP_ORDER_COIN>,
    clock: &Clock,
    key_bytes: vector<u8>,
    ctx: &mut TxContext,
) {
    lock_treasury_with_permissions(
        account,
        extensions,
        treasury_cap,
        clock,
        key_bytes,
        true,
        true,
        true,
        true,
        true,
        ctx,
    );
}

fun lock_treasury_with_permissions(
    account: &mut Account,
    extensions: &PackageRegistry,
    treasury_cap: TreasuryCap<CAP_ORDER_COIN>,
    clock: &Clock,
    key_bytes: vector<u8>,
    can_mint: bool,
    can_burn: bool,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
    ctx: &mut TxContext,
) {
    let key = key_bytes.to_string();
    let params = intents::new_params(
        key, b"Lock treasury cap".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), CurrencyIntent(), ctx,
        |intent, iw| {
            let mut action_data = vector[];
            action_data.append(bcs::to_bytes(&false)); // no max supply
            action_data.append(bcs::to_bytes(&0u64));
            action_data.append(bcs::to_bytes(&can_mint));
            action_data.append(bcs::to_bytes(&can_burn));
            action_data.append(bcs::to_bytes(&can_update_name));
            action_data.append(bcs::to_bytes(&can_update_description));
            action_data.append(bcs::to_bytes(&can_update_icon));
            action_data.append(bcs::to_bytes(&b"treasury_cap"));
            intents::add_typed_action(
                intent, currency::lock_treasury_cap_marker<CAP_ORDER_COIN>(),
                action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    executable_resources::provide_object_for_testing<TreasuryCap<CAP_ORDER_COIN>, Outcome>(
        &mut executable, b"treasury_cap".to_string(), treasury_cap, ctx,
    );
    currency::do_init_lock_treasury_cap<Config, Outcome, CAP_ORDER_COIN, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Lock a MetadataCap<CAP_ORDER_COIN> into the account.
fun lock_metadata(
    account: &mut Account,
    extensions: &PackageRegistry,
    metadata_cap: MetadataCap<CAP_ORDER_COIN>,
    clock: &Clock,
    key_bytes: vector<u8>,
    can_update_name: bool,
    can_update_description: bool,
    can_update_icon: bool,
    ctx: &mut TxContext,
) {
    let key = key_bytes.to_string();
    let params = intents::new_params(
        key, b"Lock metadata cap".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), CurrencyIntent(), ctx,
        |intent, iw| {
            let mut action_data = vector[];
            action_data.append(bcs::to_bytes(&can_update_name));
            action_data.append(bcs::to_bytes(&can_update_description));
            action_data.append(bcs::to_bytes(&can_update_icon));
            action_data.append(bcs::to_bytes(&b"metadata_cap"));
            intents::add_typed_action(
                intent, currency::lock_metadata_cap_marker<CAP_ORDER_COIN>(),
                action_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    executable_resources::provide_object_for_testing<MetadataCap<CAP_ORDER_COIN>, Outcome>(
        &mut executable, b"metadata_cap".to_string(), metadata_cap, ctx,
    );
    currency::do_init_lock_metadata_cap<Config, Outcome, CAP_ORDER_COIN, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Remove TreasuryCap<CAP_ORDER_COIN> from the account.
fun remove_treasury(
    account: &mut Account,
    extensions: &PackageRegistry,
    clock: &Clock,
    recipient: address,
    key_bytes: vector<u8>,
    ctx: &mut TxContext,
) {
    let key = key_bytes.to_string();
    let expected_cap_id = object::id(
        currency::borrow_treasury_cap_mut<CAP_ORDER_COIN>(account, extensions, version::current()),
    );
    let params = intents::new_params(
        key, b"Remove treasury cap".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), CurrencyIntent(), ctx,
        |intent, iw| {
            let resource_name = b"treasury_cap".to_string();
            let mut action_data = bcs::to_bytes(&expected_cap_id);
            action_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, currency::remove_treasury_cap_to_resources<CAP_ORDER_COIN>(),
                action_data, iw,
            );

            let mut transfer_data = bcs::to_bytes(&recipient);
            transfer_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, account_transfer::transfer_object<TreasuryCap<CAP_ORDER_COIN>>(),
                transfer_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    currency::do_init_remove_treasury_cap_to_resources<Config, Outcome, CAP_ORDER_COIN, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(), ctx,
    );
    account_transfer::do_init_transfer<Outcome, TreasuryCap<CAP_ORDER_COIN>, CurrencyIntent>(
        &mut executable, extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

/// Remove MetadataCap<CAP_ORDER_COIN> from the account.
fun remove_metadata(
    account: &mut Account,
    extensions: &PackageRegistry,
    clock: &Clock,
    recipient: address,
    key_bytes: vector<u8>,
    ctx: &mut TxContext,
) {
    let key = key_bytes.to_string();
    let expected_cap_id = {
        let metadata_cap_ref: &mut MetadataCap<CAP_ORDER_COIN> = account.borrow_managed_asset_mut_with_package_witness(
            extensions,
            currency::metadata_cap_key<CAP_ORDER_COIN>(),
            version::current(),
        );
        object::id(metadata_cap_ref)
    };
    let params = intents::new_params(
        key, b"Remove metadata cap".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), CurrencyIntent(), ctx,
        |intent, iw| {
            let resource_name = b"metadata_cap".to_string();
            let mut action_data = bcs::to_bytes(&expected_cap_id);
            action_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, currency::remove_metadata_cap_to_resources<CAP_ORDER_COIN>(),
                action_data, iw,
            );

            let mut transfer_data = bcs::to_bytes(&recipient);
            transfer_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, account_transfer::transfer_object<MetadataCap<CAP_ORDER_COIN>>(),
                transfer_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    currency::do_init_remove_metadata_cap_to_resources<Config, Outcome, CAP_ORDER_COIN, CurrencyIntent>(
        &mut executable, account, extensions, CurrencyIntent(), ctx,
    );
    account_transfer::do_init_transfer<Outcome, MetadataCap<CAP_ORDER_COIN>, CurrencyIntent>(
        &mut executable, extensions, CurrencyIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

#[test]
#[expected_failure(abort_code = currency::ECapIdMismatch, location = account_actions::currency)]
fun test_remove_treasury_cap_rejects_unexpected_cap_id() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    destroy(metadata_cap);
    lock_treasury(
        &mut account, &extensions, treasury_cap, &clock, b"lock_treasury", scenario.ctx(),
    );

    let key = b"rm_treasury_bad_id".to_string();
    let params = intents::new_params(
        key,
        b"Remove treasury cap wrong id".to_string(),
        vector[0],
        clock.timestamp_ms() + 1_000_000,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_from_address(@0xDAD));
            action_data.append(bcs::to_bytes(&b"treasury_cap".to_string()));
            intents::add_typed_action(
                intent,
                currency::remove_treasury_cap_to_resources<CAP_ORDER_COIN>(),
                action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_remove_treasury_cap_to_resources<Config, Outcome, CAP_ORDER_COIN, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );

    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = currency::ECapIdMismatch, location = account_actions::currency)]
fun test_remove_metadata_cap_rejects_unexpected_cap_id() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    destroy(treasury_cap);
    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta",
        true, true, true, scenario.ctx(),
    );

    let key = b"rm_meta_bad_id".to_string();
    let params = intents::new_params(
        key,
        b"Remove metadata cap wrong id".to_string(),
        vector[0],
        clock.timestamp_ms() + 1_000_000,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), CurrencyIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_from_address(@0xDAD));
            action_data.append(bcs::to_bytes(&b"metadata_cap".to_string()));
            intents::add_typed_action(
                intent,
                currency::remove_metadata_cap_to_resources<CAP_ORDER_COIN>(),
                action_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    currency::do_init_remove_metadata_cap_to_resources<Config, Outcome, CAP_ORDER_COIN, CurrencyIntent>(
        &mut executable, &mut account, &extensions, CurrencyIntent(), scenario.ctx(),
    );

    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

// --- Test 1: Lock MetadataCap first, then TreasuryCap ---
// Exercises the update-existing-CurrencyRules branch in do_init_lock_treasury_cap.

#[test]
fun test_lock_metadata_first_then_treasury_preserves_permissions() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    // Lock MetadataCap first — creates CurrencyRules with default mint/burn=true
    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta",
        true, true, true, scenario.ctx(),
    );

    // Verify initial rules: metadata enabled, mint/burn default to false (no TreasuryCap yet)
    let rules = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(!currency::can_mint(rules));
    assert!(!currency::can_burn(rules));
    assert!(currency::can_update_name(rules));
    assert!(currency::can_update_description(rules));
    assert!(currency::can_update_icon(rules));

    // Lock TreasuryCap — AND logic preserves existing permissions
    lock_treasury(
        &mut account, &extensions, treasury_cap, &clock, b"lock_treasury", scenario.ctx(),
    );

    // Verify updated rules: all permissions remain true after AND with true.
    let rules2 = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_mint(rules2));
    assert!(currency::can_burn(rules2));
    assert!(currency::can_update_name(rules2));
    assert!(currency::can_update_description(rules2));
    assert!(currency::can_update_icon(rules2));
    assert!(currency::has_cap<CAP_ORDER_COIN>(&account));
    assert!(currency::has_metadata_cap<CAP_ORDER_COIN>(&account));

    end(scenario, extensions, account, clock);
}

// --- Test 2: Remove MetadataCap while TreasuryCap is present ---
// Exercises the "disable metadata updates" branch in do_init_remove_metadata_cap_to_resources.

#[test]
fun test_remove_metadata_cap_with_treasury_present_disables_metadata_updates() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    // Lock both caps (standard order: treasury first)
    lock_treasury(
        &mut account, &extensions, treasury_cap, &clock, b"lock_treasury", scenario.ctx(),
    );
    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta",
        true, true, true, scenario.ctx(),
    );

    // Verify all permissions enabled
    let rules = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_mint(rules));
    assert!(currency::can_burn(rules));
    assert!(currency::can_update_name(rules));

    // Remove MetadataCap — TreasuryCap still present
    remove_metadata(
        &mut account, &extensions, &clock, RECIPIENT, b"rm_meta", scenario.ctx(),
    );

    // CurrencyRules should still exist: mint/burn enabled, metadata updates disabled
    assert!(!currency::has_metadata_cap<CAP_ORDER_COIN>(&account));
    assert!(currency::has_cap<CAP_ORDER_COIN>(&account));
    let rules2 = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_mint(rules2));
    assert!(currency::can_burn(rules2));
    assert!(!currency::can_update_name(rules2));
    assert!(!currency::can_update_description(rules2));
    assert!(!currency::can_update_icon(rules2));

    end(scenario, extensions, account, clock);
}

// --- Test 3: Remove both caps — CurrencyRules removed entirely ---
// Exercises the "remove orphaned CurrencyRules" branch in do_init_remove_metadata_cap_to_resources
// and the "disable mint/burn" branch in do_init_remove_treasury_cap_to_resources.

#[test]
fun test_remove_both_caps_removes_currency_rules() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    // Lock both caps
    lock_treasury(
        &mut account, &extensions, treasury_cap, &clock, b"lock_treasury", scenario.ctx(),
    );
    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta",
        true, true, true, scenario.ctx(),
    );

    // Remove TreasuryCap first — MetadataCap still present
    remove_treasury(
        &mut account, &extensions, &clock, RECIPIENT, b"rm_treasury", scenario.ctx(),
    );

    // CurrencyRules still exist but mint/burn disabled (MetadataCap retains rules for updates)
    assert!(!currency::has_cap<CAP_ORDER_COIN>(&account));
    assert!(currency::has_metadata_cap<CAP_ORDER_COIN>(&account));
    assert!(account.has_managed_data(currency::currency_rules_key<CAP_ORDER_COIN>()));
    let rules = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(!currency::can_mint(rules));
    assert!(!currency::can_burn(rules));

    // Remove MetadataCap — no TreasuryCap either, CurrencyRules removed
    remove_metadata(
        &mut account, &extensions, &clock, RECIPIENT, b"rm_meta", scenario.ctx(),
    );

    assert!(!currency::has_cap<CAP_ORDER_COIN>(&account));
    assert!(!currency::has_metadata_cap<CAP_ORDER_COIN>(&account));
    assert!(!account.has_managed_data(currency::currency_rules_key<CAP_ORDER_COIN>()));

    end(scenario, extensions, account, clock);
}

// --- Re-locking caps: governance can re-enable permissions via direct assignment ---

#[test]
fun test_metadata_relock_restores_permissions() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    // 1. Lock both caps (treasury first, then metadata)
    lock_treasury(
        &mut account, &extensions, treasury_cap, &clock, b"lock_treasury", scenario.ctx(),
    );
    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta",
        true, true, true, scenario.ctx(),
    );

    // Verify all permissions enabled
    let rules = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_update_name(rules));
    assert!(currency::can_update_description(rules));
    assert!(currency::can_update_icon(rules));

    // 2. Remove MetadataCap — disables metadata update permissions
    remove_metadata(
        &mut account, &extensions, &clock, RECIPIENT, b"rm_meta", scenario.ctx(),
    );
    let rules2 = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(!currency::can_update_name(rules2));
    assert!(!currency::can_update_description(rules2));
    assert!(!currency::can_update_icon(rules2));

    // 3. Retrieve the MetadataCap from RECIPIENT and re-lock it
    scenario.next_tx(RECIPIENT);
    let returned_cap = scenario.take_from_sender<MetadataCap<CAP_ORDER_COIN>>();
    scenario.next_tx(OWNER);
    lock_metadata(
        &mut account, &extensions, returned_cap, &clock, b"relock_meta",
        true, true, true, scenario.ctx(),
    );

    // 4. Re-lock with true restores permissions (no ratchet).
    let rules3 = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_update_name(rules3));
    assert!(currency::can_update_description(rules3));
    assert!(currency::can_update_icon(rules3));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_treasury_relock_reenables_mint_burn() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta_enabled",
        true, true, true, scenario.ctx(),
    );

    lock_treasury_with_permissions(
        &mut account,
        &extensions,
        treasury_cap,
        &clock,
        b"lock_treasury_disabled",
        false,
        false,
        true,
        true,
        true,
        scenario.ctx(),
    );

    let rules = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(!currency::can_mint(rules));
    assert!(!currency::can_burn(rules));

    remove_treasury(
        &mut account, &extensions, &clock, RECIPIENT, b"rm_treasury_disabled", scenario.ctx(),
    );

    scenario.next_tx(RECIPIENT);
    let returned_cap = scenario.take_from_sender<TreasuryCap<CAP_ORDER_COIN>>();
    scenario.next_tx(OWNER);

    lock_treasury_with_permissions(
        &mut account,
        &extensions,
        returned_cap,
        &clock,
        b"relock_treasury_disabled",
        true,
        true,
        true,
        true,
        true,
        scenario.ctx(),
    );

    let rules_after = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_mint(rules_after));
    assert!(currency::can_burn(rules_after));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_metadata_relock_reenables_false_permissions() {
    let (mut scenario, extensions, mut account, clock, treasury_cap, metadata_cap) =
        start_with_both_caps();

    lock_treasury(
        &mut account, &extensions, treasury_cap, &clock, b"lock_treasury", scenario.ctx(),
    );
    lock_metadata(
        &mut account, &extensions, metadata_cap, &clock, b"lock_meta_disabled",
        false, false, false, scenario.ctx(),
    );

    let rules = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(!currency::can_update_name(rules));
    assert!(!currency::can_update_description(rules));
    assert!(!currency::can_update_icon(rules));

    remove_metadata(
        &mut account, &extensions, &clock, RECIPIENT, b"rm_meta_disabled", scenario.ctx(),
    );

    scenario.next_tx(RECIPIENT);
    let returned_cap = scenario.take_from_sender<MetadataCap<CAP_ORDER_COIN>>();
    scenario.next_tx(OWNER);

    lock_metadata(
        &mut account, &extensions, returned_cap, &clock, b"relock_meta_disabled",
        true, true, true, scenario.ctx(),
    );

    let rules_after = currency::borrow_rules<CAP_ORDER_COIN>(&account, &extensions);
    assert!(currency::can_update_name(rules_after));
    assert!(currency::can_update_description(rules_after));
    assert!(currency::can_update_icon(rules_after));

    end(scenario, extensions, account, clock);
}
