#[test_only]
module account_protocol::config_intents_tests;

use account_protocol::account::{Self, Account};
use account_protocol::metadata;
use account_protocol::config;
use account_protocol::deps;
use account_protocol::intents::{Self, PendingIntent};
use account_protocol::package_registry::{
    Self as package_registry,
    PackageRegistry,
    PackageAdminCap
};
use account_protocol::version;
use std::type_name;
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

// === Imports ===

// === Constants ===

const OWNER: address = @0xCAFE;
const CUSTOM_PKG: address = @0xDEAD;

// === Structs ===

public struct Witness() has copy, drop;
public struct WrongWitness() has copy, drop;
public struct DummyIntent() has drop;

public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock, PackageAdminCap) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    package_registry::init_for_testing(scenario.ctx());
    account::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    // add core deps
    package_registry::add_for_testing(
        &mut extensions,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    package_registry::add_for_testing(&mut extensions, b"AccountConfig".to_string(), @0x1, 1);
    package_registry::add_for_testing(&mut extensions, b"AccountActions".to_string(), @0x2, 1);
    // add external dep
    package_registry::add_for_testing(&mut extensions, b"External".to_string(), @0xABC, 1);

    let deps = deps::new(&extensions);
    let account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    // create world
    (scenario, extensions, account, clock, cap)
}

fun end(
    scenario: Scenario,
    extensions: PackageRegistry,
    account: Account,
    clock: Clock,
    cap: PackageAdminCap,
) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    destroy(cap);
    ts::end(scenario);
}

/// Create a dummy intent for testing
fun create_dummy_intent(
    scenario: &mut Scenario,
    account: &Account,
    registry: &PackageRegistry,
    clock: &Clock,
): PendingIntent<Outcome> {
    let params = intents::new_params(
        b"dummy".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        clock,
        scenario.ctx(),
    );
    account.create_intent(
        registry,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    )
}

/// Helper to add set_authorization_level spec to intent
fun add_set_authorization_level_spec(intent: &mut PendingIntent<Outcome>, level: u8) {
    // SetAuthorizationLevelAction { level: u8 }
    let action_data = bcs::to_bytes(&level);
    intents::add_action_spec(
        intent,
        config::config_set_authorization_level(),
        action_data,
        DummyIntent(),
    );
}

/// Helper to add add_dep spec to intent
fun add_add_dep_spec(
    intent: &mut PendingIntent<Outcome>,
    addr: address,
    name: std::string::String,
    dep_version: u64,
) {
    // AddDepAction { addr, name, version }
    let mut action_data = bcs::to_bytes(&addr);
    vector::append(&mut action_data, bcs::to_bytes(&name));
    vector::append(&mut action_data, bcs::to_bytes(&dep_version));
    intents::add_action_spec(
        intent,
        config::config_add_dep(),
        action_data,
        DummyIntent(),
    );
}

/// Helper to add remove_dep spec to intent
fun add_remove_dep_spec(intent: &mut PendingIntent<Outcome>, addr: address) {
    // RemoveDepAction { addr }
    let action_data = bcs::to_bytes(&addr);
    intents::add_action_spec(
        intent,
        config::config_remove_dep(),
        action_data,
        DummyIntent(),
    );
}

// === Tests ===

// NOTE: test_edit_config_metadata removed - edit_metadata function was deleted

// === Per-Account Deps Tests (3-Layer Pattern) ===

#[test]
fun test_set_authorization_level() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let key = b"dummy".to_string();

    // Initially authorization level is GLOBAL_ONLY (0)
    assert!(account.deps().authorization_level() == deps::auth_level_global_only());

    // Create intent to set to WHITELIST (1)
    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_set_authorization_level_spec(&mut intent, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    // Execute the intent
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    config::do_set_authorization_level<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut account,
        &extensions,
        DummyIntent(),
    );

    account.confirm_execution(executable);

    // Now authorization level should be WHITELIST (1)
    assert!(account.deps().authorization_level() == deps::auth_level_whitelist());

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_noop_set_authorization_level_does_not_stale_pending_intents() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let victim_key = b"victim".to_string();
    let noop_key = b"noop".to_string();

    assert!(account.deps().authorization_level() == deps::auth_level_global_only());

    let victim_params = intents::new_params(
        victim_key,
        b"Victim intent".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut victim_intent = account.create_intent(
        &extensions,
        victim_params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_set_authorization_level_spec(&mut victim_intent, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, victim_intent, version::current(), DummyIntent());

    let noop_params = intents::new_params(
        noop_key,
        b"No-op auth level".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut noop_intent = account.create_intent(
        &extensions,
        noop_params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_set_authorization_level_spec(&mut noop_intent, deps::auth_level_global_only());
    account.insert_intent_unshared(&extensions, noop_intent, version::current(), DummyIntent());

    let (_, mut noop_exec) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        noop_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_set_authorization_level<Config, Outcome, DummyIntent>(
        &mut noop_exec,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(noop_exec);

    assert!(account.deps().authorization_level() == deps::auth_level_global_only());

    let (_, mut victim_exec) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        victim_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_set_authorization_level<Config, Outcome, DummyIntent>(
        &mut victim_exec,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(victim_exec);

    assert!(account.deps().authorization_level() == deps::auth_level_whitelist());

    end(scenario, extensions, account, clock, cap);
}

#[test]
#[expected_failure(abort_code = intents::EWrongAccount, location = account_protocol::intents)]
fun test_noop_set_authorization_level_checks_executable_account_binding() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let mut other_account = account::new(
        Config {},
        metadata::empty(),
        deps::new(&extensions),
        Witness(),
        scenario.ctx(),
    );
    let key = b"noop_binding".to_string();

    let params = intents::new_params(
        key,
        b"No-op binding".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent = account.create_intent(
        &extensions,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_set_authorization_level_spec(&mut intent, deps::auth_level_global_only());
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_set_authorization_level<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut other_account,
        &extensions,
        DummyIntent(),
    );

    account.confirm_execution(executable);
    end(scenario, extensions, account, clock, cap);
    destroy(other_account);
}

#[test]
fun test_add_dep_from_global_registry() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let key = b"dummy".to_string();

    // External package @0xABC is already in global registry from start()
    let external_addr = @0xABC;

    // Create intent with add_dep action
    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_add_dep_spec(&mut intent, external_addr, b"External".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    // Execute the intent
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut account,
        &extensions,
        DummyIntent(),
    );

    account.confirm_execution(executable);

    // Verify the dep was added to per-account table
    assert!(deps::contains_dep(account.account_deps(), external_addr));
    let info = deps::get_dep(account.account_deps(), external_addr);
    assert!(deps::dep_name(info) == b"External".to_string());
    assert!(deps::dep_version(info) == 1);

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_add_dep_uses_current_add_only_global_registry() {
    let (mut scenario, mut extensions, mut account, clock, cap) = start();
    let key = b"future_dep".to_string();
    let future_addr = @0xDAD;

    let params = intents::new_params(
        key,
        b"Future dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent = account.create_intent(
        &extensions,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut intent, future_addr, b"Future".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    package_registry::add_for_testing(&mut extensions, b"Future".to_string(), future_addr, 1);

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(executable);
    assert!(deps::contains_dep(account.account_deps(), future_addr));

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_create_executable_revalidates_intent_after_local_policy_change() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let stale_key = b"stale".to_string();
    let bump_key = b"bump".to_string();

    let params1 = intents::new_params(
        stale_key,
        b"Older staged intent".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut stale_intent = account.create_intent(
        &extensions,
        params1,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_set_authorization_level_spec(&mut stale_intent, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, stale_intent, version::current(), DummyIntent());

    let params2 = intents::new_params(
        bump_key,
        b"Mutate local policy".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut bump_intent = account.create_intent(
        &extensions,
        params2,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut bump_intent, @0xABC, b"External".to_string(), 1);
    account.insert_intent_unshared(&extensions, bump_intent, version::current(), DummyIntent());

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        bump_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(executable);

    assert!(deps::contains_dep(account.account_deps(), @0xABC));

    let (outcome, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        stale_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    destroy(outcome);
    config::do_set_authorization_level<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(executable);
    assert!(account.deps().authorization_level() == deps::auth_level_whitelist());

    end(scenario, extensions, account, clock, cap);
}

#[test]
#[expected_failure(abort_code = account::EDepNamesMissing, location = account_protocol::account)]
fun test_add_dep_fails_closed_without_dep_names_key() {
    let (mut scenario, mut extensions, mut account, clock, cap) = start();
    let external_addr = @0xABC;
    let second_addr = @0xDEF;

    let add_key = b"add_existing".to_string();
    let params1 = intents::new_params(
        add_key,
        b"Add first dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent1 = account.create_intent(
        &extensions,
        params1,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut intent1, external_addr, b"External".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent1, version::current(), DummyIntent());

    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        add_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut exec1,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec1);

    package_registry::add_for_testing(&mut extensions, b"Second".to_string(), second_addr, 1);
    assert!(account::has_dep_names(&account));
    account::remove_dep_names_key_for_testing(&mut account);
    assert!(!account::has_dep_names(&account));

    let second_key = b"add_second".to_string();
    let params2 = intents::new_params(
        second_key,
        b"Add second dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent2 = account.create_intent(
        &extensions,
        params2,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut intent2, second_addr, b"Second".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent2, version::current(), DummyIntent());

    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        second_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut exec2,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec2);

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_add_unverified_dep_after_set_whitelist() {
    let (mut scenario, extensions, mut account, clock, cap) = start();

    // First, set authorization level to WHITELIST
    let key1 = b"set_level".to_string();
    let params1 = intents::new_params(
        key1,
        b"Set to WHITELIST".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent1 = account.create_intent(
        &extensions,
        params1,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_set_authorization_level_spec(&mut intent1, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, intent1, version::current(), DummyIntent());

    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key1,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_set_authorization_level<Config, Outcome, DummyIntent>(
        &mut exec1,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec1);

    assert!(account.deps().authorization_level() == deps::auth_level_whitelist());

    // Now add an unverified package (not in global registry)
    let key2 = b"add_unverified".to_string();
    let params2 = intents::new_params(
        key2,
        b"Add unverified dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent2 = account.create_intent(
        &extensions,
        params2,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut intent2, CUSTOM_PKG, b"CustomPkg".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent2, version::current(), DummyIntent());

    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key2,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut exec2,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec2);

    // Verify unverified dep was added
    assert!(deps::contains_dep(account.account_deps(), CUSTOM_PKG));

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_remove_dep() {
    let (mut scenario, extensions, mut account, clock, cap) = start();

    // First, add a dep from global registry
    let external_addr = @0xABC;
    let key1 = b"add".to_string();
    let params1 = intents::new_params(
        key1,
        b"Add dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent1 = account.create_intent(
        &extensions,
        params1,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut intent1, external_addr, b"External".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent1, version::current(), DummyIntent());

    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key1,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut exec1,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec1);

    // Verify it was added
    assert!(deps::contains_dep(account.account_deps(), external_addr));

    // Now remove it
    let key2 = b"remove".to_string();
    let params2 = intents::new_params(
        key2,
        b"Remove dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent2 = account.create_intent(
        &extensions,
        params2,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_remove_dep_spec(&mut intent2, external_addr);
    account.insert_intent_unshared(&extensions, intent2, version::current(), DummyIntent());

    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key2,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_remove_dep<Config, Outcome, DummyIntent>(
        &mut exec2,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec2);

    // Verify it was removed
    assert!(!deps::contains_dep(account.account_deps(), external_addr));

    end(scenario, extensions, account, clock, cap);
}

#[test]
#[expected_failure(abort_code = account::EDepNamesMissing, location = account_protocol::account)]
fun test_remove_dep_fails_closed_without_dep_names_key() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let external_addr = @0xABC;

    let add_key = b"add".to_string();
    let params1 = intents::new_params(
        add_key,
        b"Add dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent1 = account.create_intent(
        &extensions,
        params1,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_add_dep_spec(&mut intent1, external_addr, b"External".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent1, version::current(), DummyIntent());

    let (_, mut exec1) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        add_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut exec1,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec1);

    assert!(account::has_dep_names(&account));
    account::remove_dep_names_key_for_testing(&mut account);
    assert!(!account::has_dep_names(&account));

    let remove_key = b"remove".to_string();
    let params2 = intents::new_params(
        remove_key,
        b"Remove dep".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent2 = account.create_intent(
        &extensions,
        params2,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_remove_dep_spec(&mut intent2, external_addr);
    account.insert_intent_unshared(&extensions, intent2, version::current(), DummyIntent());

    let (_, mut exec2) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        remove_key,
        &clock,
        Witness(),
        scenario.ctx(),
    );
    config::do_remove_dep<Config, Outcome, DummyIntent>(
        &mut exec2,
        &mut account,
        &extensions,
        DummyIntent(),
    );
    account.confirm_execution(exec2);

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_delete_set_authorization_level_expired() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    // Create intent with set authorization level action
    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_set_authorization_level_spec(&mut intent, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    // Delete as expired
    destroy(account.delete_expired_intent<Outcome, Witness>(key, &clock, Witness(), scenario.ctx()));

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_delete_add_dep_expired() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    // Create intent with add_dep action
    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_add_dep_spec(&mut intent, @0xABC, b"External".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    // Delete as expired
    destroy(account.delete_expired_intent<Outcome, Witness>(key, &clock, Witness(), scenario.ctx()));

    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_delete_remove_dep_expired() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    // Create intent with remove_dep action
    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_remove_dep_spec(&mut intent, @0xABC);
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    // Delete as expired
    destroy(account.delete_expired_intent<Outcome, Witness>(key, &clock, Witness(), scenario.ctx()));

    end(scenario, extensions, account, clock, cap);
}

#[test]
#[expected_failure(abort_code = account::EHasntExpired, location = account_protocol::account)]
fun test_delete_expired_intent_rejects_unexpired_intent() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"never_expire".to_string();

    let params = intents::new_params(
        key,
        b"not expired".to_string(),
        vector[0],
        clock.timestamp_ms() + 10,
        &clock,
        scenario.ctx(),
    );
    let mut intent = account.create_intent(
        &extensions,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    add_set_authorization_level_spec(&mut intent, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    destroy(account.delete_expired_intent<Outcome, Witness>(
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    ));

    end(scenario, extensions, account, clock, cap);
}

#[test]
#[expected_failure(abort_code = account::ENotConfigModule, location = account_protocol::account)]
fun test_delete_expired_intent_rejects_wrong_config_witness() {
    let (mut scenario, extensions, mut account, mut clock, cap) = start();
    clock.increment_for_testing(1);
    let key = b"dummy".to_string();

    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_set_authorization_level_spec(&mut intent, deps::auth_level_whitelist());
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    destroy(account.delete_expired_intent<Outcome, WrongWitness>(
        key,
        &clock,
        WrongWitness(),
        scenario.ctx(),
    ));

    end(scenario, extensions, account, clock, cap);
}

#[test, expected_failure(abort_code = config::EPackageNotAuthorized)]
fun test_error_add_unverified_dep_when_global_only() {
    let (mut scenario, extensions, mut account, clock, cap) = start();
    let key = b"dummy".to_string();

    // authorization level is GLOBAL_ONLY by default
    assert!(account.deps().authorization_level() == deps::auth_level_global_only());

    // Try to add an unverified package (not in global registry) - should fail
    let mut intent = create_dummy_intent(&mut scenario, &account, &extensions, &clock);
    add_add_dep_spec(&mut intent, CUSTOM_PKG, b"CustomPkg".to_string(), 1);
    account.insert_intent_unshared(&extensions, intent, version::current(), DummyIntent());

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    // This should fail because CUSTOM_PKG is not in global registry and level is GLOBAL_ONLY
    config::do_add_dep<Config, Outcome, DummyIntent>(
        &mut executable,
        &mut account,
        &extensions,
        DummyIntent(),
    );

    // unreachable
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock, cap);
}

#[test]
fun test_add_dep_spec() {
    let (scenario, extensions, mut account, clock, cap) = start();

    // Verify the account_deps table starts empty
    let external_addr = @0xABC;
    assert!(!deps::contains_dep(account.account_deps(), external_addr));

    end(scenario, extensions, account, clock, cap);
}
