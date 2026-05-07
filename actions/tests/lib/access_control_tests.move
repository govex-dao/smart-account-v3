#[test_only]
module account_actions::access_control_tests;

use account_actions::access_control;
use account_actions::actions_version as version;
use account_protocol::account::{Self, Account};
use account_protocol::metadata;
use account_protocol::deps;
use account_protocol::executable_resources;
use account_protocol::intent_interface;
use account_protocol::intents;
use account_protocol::owned;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageRegistry,
    PackageAdminCap
};
use sui::bcs;
use sui::clock::{Self, Clock};
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
public struct ACIntent() has copy, drop;

// Test capability that needs to be locked
public struct TestCap has key, store {
    id: UID,
    value: u64,
}

// Second cap type for multi-cap tests
public struct AnotherCap has key, store {
    id: UID,
}

// === Helpers ===

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    package_registry::add_for_testing(
        &mut extensions,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
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

/// Helper: lock a cap into the account via the intent pipeline.
/// Uses ProvideObjectToResources + AccessControlLock two-action pattern.
fun lock_cap_via_intent(
    account: &mut Account,
    extensions: &PackageRegistry,
    cap: TestCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let cap_id = object::id(&cap);
    let resource_name = b"cap".to_string();
    let key = b"lock_cap".to_string();
    let params = intents::new_params(
        key, b"Lock cap".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, clock, ctx,
    );
    account.build_intent!(
        extensions, params, Outcome {},
        version::current(), ACIntent(), ctx,
        |intent, iw| {
            // Action 1: ProvideObjectToResources — deposit cap into resources
            let mut provide_data = bcs::to_bytes(&cap_id);
            provide_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, owned::provide_object_to_resources<TestCap>(), provide_data, iw,
            );
            // Action 2: AccessControlLock — take from resources and lock
            let mut lock_data = bcs::to_bytes(&cap_id);
            lock_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, access_control::access_control_lock<TestCap>(), lock_data, iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        extensions, key, clock, Witness(), ctx,
    );
    owned::do_provide_object<Outcome, TestCap, ACIntent>(
        &mut executable, account, extensions, ACIntent(), cap, ctx,
    );
    access_control::do_lock<Config, Outcome, TestCap, ACIntent>(
        &mut executable, account, extensions, ACIntent(),
    );
    account.confirm_execution(executable);
    destroy(account.destroy_empty_intent<Outcome, Witness>(key, Witness(), ctx));
}

// === Tests ===

#[test]
fun test_lock_cap_basic() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Create a test capability
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 42,
    };

    // Get auth and lock the capability (test-only helper)
    let auth = account.new_auth<Config, Witness>(Witness());
    access_control::lock_cap<Config, TestCap>(auth, &mut account, &extensions, test_cap);

    // Verify the cap is locked
    assert!(access_control::has_lock<Config, TestCap>(&account));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_cap_via_intent() {
    let (mut scenario, extensions, mut account, clock) = start();

    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 99,
    };

    lock_cap_via_intent(&mut account, &extensions, test_cap, &clock, scenario.ctx());

    assert!(access_control::has_lock<Config, TestCap>(&account));

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = access_control::ECapIdMismatch, location = account_actions::access_control)]
fun test_lock_cap_rejects_unexpected_cap_id() {
    let (mut scenario, extensions, mut account, clock) = start();

    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 7,
    };
    let resource_name = b"cap".to_string();

    let key = b"lock_cap_bad_id".to_string();
    let params = intents::new_params(
        key, b"Lock cap wrong id".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), ACIntent(), scenario.ctx(),
        |intent, iw| {
            // Action 1: ProvideObjectToResources
            let cap_id = object::id(&test_cap);
            let mut provide_data = bcs::to_bytes(&cap_id);
            provide_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, owned::provide_object_to_resources<TestCap>(), provide_data, iw,
            );
            // Action 2: AccessControlLock with WRONG expected_id
            let mut lock_data = bcs::to_bytes(&object::id_from_address(@0xDAD));
            lock_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, access_control::access_control_lock<TestCap>(), lock_data, iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    owned::do_provide_object<Outcome, TestCap, ACIntent>(
        &mut executable, &account, &extensions, ACIntent(), test_cap, scenario.ctx(),
    );
    access_control::do_lock<Config, Outcome, TestCap, ACIntent>(
        &mut executable, &mut account, &extensions, ACIntent(),
    );

    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = owned::EWrongObject, location = account_protocol::owned)]
fun test_provide_object_rejects_unexpected_object_id() {
    let (mut scenario, extensions, mut account, clock) = start();

    let approved_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 1,
    };
    let attacker_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 2,
    };
    let approved_cap_id = object::id(&approved_cap);
    let resource_name = b"cap".to_string();
    let key = b"provide_wrong_object".to_string();

    let params = intents::new_params(
        key,
        b"Provide wrong cap".to_string(),
        vector[0],
        clock.timestamp_ms() + 1_000_000,
        &clock,
        scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), ACIntent(), scenario.ctx(),
        |intent, iw| {
            let mut provide_data = bcs::to_bytes(&approved_cap_id);
            provide_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent, owned::provide_object_to_resources<TestCap>(), provide_data, iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    owned::do_provide_object<Outcome, TestCap, ACIntent>(
        &mut executable, &account, &extensions, ACIntent(), attacker_cap, scenario.ctx(),
    );

    destroy(approved_cap);
    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_unlock_to_resources() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock a cap first
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 77,
    };
    let test_cap_id = object::id(&test_cap);
    lock_cap_via_intent(&mut account, &extensions, test_cap, &clock, scenario.ctx());
    assert!(access_control::has_lock<Config, TestCap>(&account));

    // Unlock into executable_resources via intent
    let key = b"unlock_cap".to_string();
    let resource_name = b"cap_out".to_string();
    let params = intents::new_params(
        key, b"Unlock cap".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), ACIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&test_cap_id);
            action_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent,
                access_control::access_control_unlock_to_resources<TestCap>(),
                action_data,
                iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    access_control::do_unlock_to_resources<Config, Outcome, TestCap, ACIntent>(
        &mut executable, &mut account, &extensions, ACIntent(), scenario.ctx(),
    );
    let unlocked_cap = executable_resources::take_object_for_testing<TestCap, Outcome>(
        &mut executable,
        resource_name,
    );
    let TestCap { id, value } = unlocked_cap;
    assert!(value == 77);
    object::delete(id);
    account.confirm_execution(executable);

    // Cap should no longer be locked
    assert!(!access_control::has_lock<Config, TestCap>(&account));

    end(scenario, extensions, account, clock);
}

#[test]
#[expected_failure(abort_code = access_control::ECapIdMismatch, location = account_actions::access_control)]
fun test_unlock_to_resources_rejects_unexpected_cap_id() {
    let (mut scenario, extensions, mut account, clock) = start();

    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 77,
    };
    lock_cap_via_intent(&mut account, &extensions, test_cap, &clock, scenario.ctx());

    let key = b"unlock_cap_bad_id".to_string();
    let resource_name = b"cap_out".to_string();
    let params = intents::new_params(
        key, b"Unlock cap wrong id".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), ACIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&object::id_from_address(@0xDAD));
            action_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent,
                access_control::access_control_unlock_to_resources<TestCap>(),
                action_data,
                iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    access_control::do_unlock_to_resources<Config, Outcome, TestCap, ACIntent>(
        &mut executable, &mut account, &extensions, ACIntent(), scenario.ctx(),
    );

    account.confirm_execution(executable);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_multiple_cap_types() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock TestCap
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 1,
    };
    lock_cap_via_intent(&mut account, &extensions, test_cap, &clock, scenario.ctx());

    // Lock AnotherCap via direct auth (test-only)
    let another_cap = AnotherCap {
        id: object::new(scenario.ctx()),
    };
    let auth = account.new_auth<Config, Witness>(Witness());
    access_control::lock_cap<Config, AnotherCap>(auth, &mut account, &extensions, another_cap);

    // Both are locked
    assert!(access_control::has_lock<Config, TestCap>(&account));
    assert!(access_control::has_lock<Config, AnotherCap>(&account));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_has_lock_false_when_empty() {
    let (scenario, extensions, account, clock) = start();

    // Nothing locked yet
    assert!(!access_control::has_lock<Config, TestCap>(&account));
    assert!(!access_control::has_lock<Config, AnotherCap>(&account));

    end(scenario, extensions, account, clock);
}

#[test]
fun test_lock_and_unlock_round_trip() {
    let (mut scenario, extensions, mut account, clock) = start();

    // Lock
    let test_cap = TestCap {
        id: object::new(scenario.ctx()),
        value: 55,
    };
    let test_cap_id = object::id(&test_cap);
    lock_cap_via_intent(&mut account, &extensions, test_cap, &clock, scenario.ctx());
    assert!(access_control::has_lock<Config, TestCap>(&account));

    // Unlock to resources
    let key = b"unlock".to_string();
    let resource_name = b"cap_out".to_string();
    let params = intents::new_params(
        key, b"Unlock".to_string(), vector[0], clock.timestamp_ms() + 1_000_000, &clock, scenario.ctx(),
    );
    account.build_intent!(
        &extensions, params, Outcome {},
        version::current(), ACIntent(), scenario.ctx(),
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&test_cap_id);
            action_data.append(bcs::to_bytes(&resource_name));
            intents::add_typed_action(
                intent,
                access_control::access_control_unlock_to_resources<TestCap>(),
                action_data,
                iw,
            );
        },
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &extensions, key, &clock, Witness(), scenario.ctx(),
    );
    access_control::do_unlock_to_resources<Config, Outcome, TestCap, ACIntent>(
        &mut executable, &mut account, &extensions, ACIntent(), scenario.ctx(),
    );
    let unlocked_cap = executable_resources::take_object_for_testing<TestCap, Outcome>(
        &mut executable,
        resource_name,
    );
    account.confirm_execution(executable);
    assert!(!access_control::has_lock<Config, TestCap>(&account));

    // Re-lock the same cap after pulling it back out of resources.
    lock_cap_via_intent(&mut account, &extensions, unlocked_cap, &clock, scenario.ctx());
    assert!(access_control::has_lock<Config, TestCap>(&account));

    end(scenario, extensions, account, clock);
}
