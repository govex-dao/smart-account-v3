#[test_only]
module account_actions::package_upgrade_tests;

use account_actions::actions_version as version;
use account_actions::package_upgrade as pkg_upgrade;
use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::executable_resources;
use account_protocol::intent_interface;
use account_protocol::intents;
use account_protocol::metadata;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageAdminCap,
    PackageRegistry,
};
use std::string::String;
use sui::bcs;
use sui::clock::{Self, Clock};
use sui::object::{Self, ID};
use sui::package::{Self, UpgradeCap};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

use fun intent_interface::build_intent as Account.build_intent;

const OWNER: address = @0xCAFE;
const RESOURCE_NAME: vector<u8> = b"upgrade_cap";

public struct Witness has drop {}
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}
public struct PackageUpgradeIntent has copy, drop {}

fun start(): (Scenario, PackageRegistry, Account, Clock) {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);

    let mut registry = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();
    package_registry::add_for_testing(
        &mut registry,
        b"AccountActions".to_string(),
        @account_actions,
        1,
    );

    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));
    let account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness {},
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    destroy(cap);
    (scenario, registry, account, clock)
}

fun end(scenario: Scenario, registry: PackageRegistry, account: Account, clock: Clock) {
    destroy(registry);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

fun create_upgrade_cap(package_addr: address, ctx: &mut TxContext): UpgradeCap {
    package::test_publish(package_addr.to_id(), ctx)
}

fun new_account_for_testing(registry: &PackageRegistry, ctx: &mut TxContext): Account {
    let deps = deps::new_for_testing(registry, object::id_from_address(@0x0));
    account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness {},
        ctx,
    )
}

fun lock_cap(
    account: &mut Account,
    registry: &PackageRegistry,
    cap: UpgradeCap,
    package_name: String,
    delay_ms: u64,
) {
    let auth = account.new_auth<Config, Witness>(Witness {});
    pkg_upgrade::lock_cap(auth, account, registry, cap, package_name, delay_ms);
}

fun locked_cap_id(
    account: &Account,
    registry: &PackageRegistry,
    package_name: String,
): ID {
    let package_addr = pkg_upgrade::get_package_addr(account, registry, package_name);
    object::id(pkg_upgrade::borrow_cap(account, registry, package_addr))
}

fun stage_upgrade_and_commit(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    package_name: String,
    digest: vector<u8>,
    expected_cap_id: ID,
    execution_time: u64,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let params = intents::new_params(
        key,
        b"Upgrade package".to_string(),
        vector[execution_time],
        expiration_time,
        clock,
        ctx,
    );

    account.build_intent!(
        registry,
        params,
        Outcome {},
        version::current(),
        PackageUpgradeIntent {},
        ctx,
        |intent, iw| {
            let mut upgrade_data = bcs::to_bytes(&package_name);
            vector::append(&mut upgrade_data, bcs::to_bytes(&digest));
            vector::append(&mut upgrade_data, bcs::to_bytes(&expected_cap_id.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_upgrade_marker(),
                upgrade_data,
                iw,
            );

            let mut commit_data = bcs::to_bytes(&package_name);
            vector::append(&mut commit_data, bcs::to_bytes(&expected_cap_id.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_commit_marker(),
                commit_data,
                iw,
            );
        },
    );
}

fun stage_restrict(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    package_name: String,
    policy: u8,
    expected_cap_id: ID,
    execution_time: u64,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let params = intents::new_params(
        key,
        b"Restrict package policy".to_string(),
        vector[execution_time],
        expiration_time,
        clock,
        ctx,
    );

    account.build_intent!(
        registry,
        params,
        Outcome {},
        version::current(),
        PackageUpgradeIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&package_name);
            vector::append(&mut action_data, bcs::to_bytes(&policy));
            vector::append(&mut action_data, bcs::to_bytes(&expected_cap_id.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_restrict_marker(),
                action_data,
                iw,
            );
        },
    );
}

#[test]
fun test_lock_cap_tracks_index_and_rules() {
    let (mut scenario, registry, mut account, clock) = start();

    let package_name = b"govex_core".to_string();
    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 1_000);

    assert!(pkg_upgrade::has_cap(&account, package_name));
    assert!(pkg_upgrade::get_time_delay(&account, &registry, package_name) == 1_000);

    let package_addr = pkg_upgrade::get_cap_package(&account, &registry, package_name);
    assert!(pkg_upgrade::is_package_managed(&account, &registry, package_addr));
    assert!(pkg_upgrade::get_package_addr(&account, &registry, package_name) == package_addr);
    assert!(pkg_upgrade::get_package_name(&account, &registry, package_addr) == package_name);

    end(scenario, registry, account, clock);
}

#[test]
fun test_lock_cap_allows_unique_package_names() {
    let (mut scenario, registry, mut account, clock) = start();
    let package_a = b"govex_core".to_string();
    let package_b = b"govex_aux".to_string();

    let cap_a = create_upgrade_cap(@0x1, scenario.ctx());
    let cap_b = create_upgrade_cap(@0x2, scenario.ctx());
    lock_cap(&mut account, &registry, cap_a, package_a, 0);
    lock_cap(&mut account, &registry, cap_b, package_b, 0);
    let expected_cap_id_a = locked_cap_id(&account, &registry, package_a);
    let expected_cap_id_b = locked_cap_id(&account, &registry, package_b);

    assert!(pkg_upgrade::has_cap(&account, package_a));
    assert!(pkg_upgrade::has_cap(&account, package_b));
    assert!(pkg_upgrade::get_package_addr(&account, &registry, package_a) == @0x1);
    assert!(pkg_upgrade::get_package_addr(&account, &registry, package_b) == @0x2);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::ELockAlreadyExists)]
fun test_lock_cap_twice_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let package_name = b"govex_core".to_string();

    let cap_a = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap_a, package_name, 0);

    let cap_b = create_upgrade_cap(@0x2, scenario.ctx());
    lock_cap(&mut account, &registry, cap_b, package_name, 0);

    end(scenario, registry, account, clock);
}

#[test]
fun test_lock_cap_allows_reuse_after_immutable() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"immutable_then_relock".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_restrict(
        &mut account,
        &registry,
        key,
        package_name,
        pkg_upgrade::immutable_policy(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);
    assert!(!pkg_upgrade::has_cap(&account, package_name));

    // After making immutable, the name is freed and can be reused
    let new_cap = create_upgrade_cap(@0x3, scenario.ctx());
    lock_cap(&mut account, &registry, new_cap, package_name, 0);
    assert!(pkg_upgrade::has_cap(&account, package_name));
    assert!(pkg_upgrade::get_cap_package(&account, &registry, package_name) == @0x3);

    end(scenario, registry, account, clock);
}

#[test]
fun test_do_init_upgrade_and_commit_updates_index() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"upgrade_flow".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let old_addr = pkg_upgrade::get_cap_package(&account, &registry, package_name);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_upgrade_and_commit(
        &mut account,
        &registry,
        key,
        package_name,
        b"digest-v2",
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    let ticket = pkg_upgrade::do_init_upgrade<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        &clock,
        PackageUpgradeIntent {},
    );
    let receipt = ticket.test_upgrade();

    pkg_upgrade::do_init_commit<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        receipt,
        PackageUpgradeIntent {},
    );

    account.confirm_execution(executable);
    let new_addr = pkg_upgrade::get_cap_package(&account, &registry, package_name);
    assert!(new_addr != old_addr);
    assert!(pkg_upgrade::get_package_addr(&account, &registry, package_name) == new_addr);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeTooEarly)]
fun test_do_init_upgrade_enforces_time_delay() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"upgrade_delay".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 1_000);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_upgrade_and_commit(
        &mut account,
        &registry,
        key,
        package_name,
        b"digest-v2",
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    let ticket = pkg_upgrade::do_init_upgrade<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        &clock,
        PackageUpgradeIntent {},
    );
    let receipt = ticket.test_upgrade();
    pkg_upgrade::do_init_commit<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        receipt,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock);
}

#[test]
fun test_do_init_restrict_additive_policy() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"restrict_additive".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_restrict(
        &mut account,
        &registry,
        key,
        package_name,
        package::additive_policy(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    assert!(
        pkg_upgrade::get_cap_policy(&account, &registry, package_name) == package::additive_policy()
    );

    end(scenario, registry, account, clock);
}

#[test]
fun test_do_init_restrict_immutable_policy() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"restrict_immutable".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_restrict(
        &mut account,
        &registry,
        key,
        package_name,
        pkg_upgrade::immutable_policy(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    // Cap removed
    assert!(!pkg_upgrade::has_cap(&account, package_name));
    // Index entry cleaned up
    assert!(!pkg_upgrade::is_package_managed(&account, &registry, @0x1));

    end(scenario, registry, account, clock);
}

#[test]
fun test_get_cap_version_and_policy_match_locked_cap() {
    let (mut scenario, registry, mut account, clock) = start();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    let version_before_lock = cap.version();
    let policy_before_lock = cap.policy();
    lock_cap(&mut account, &registry, cap, package_name, 0);

    assert!(
        pkg_upgrade::get_cap_version(&account, &registry, package_name) == version_before_lock
    );
    assert!(
        pkg_upgrade::get_cap_policy(&account, &registry, package_name) == policy_before_lock
    );

    end(scenario, registry, account, clock);
}

#[test]
fun test_is_package_managed_false_when_nothing_locked() {
    let (scenario, registry, account, clock) = start();
    assert!(!pkg_upgrade::is_package_managed(&account, &registry, @0x999));
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EPackageDoesntExist)]
fun test_get_package_name_aborts_for_unknown_package() {
    let (mut scenario, registry, mut account, clock) = start();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);

    let _name = pkg_upgrade::get_package_name(&account, &registry, @0x2);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EEmptyPackageName)]
fun test_lock_cap_rejects_empty_name() {
    let (mut scenario, registry, mut account, clock) = start();
    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, b"".to_string(), 0);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EInvalidPolicy)]
fun test_do_init_restrict_rejects_unknown_policy() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"restrict_invalid".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_restrict(
        &mut account,
        &registry,
        key,
        package_name,
        42,
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EPolicyShouldRestrict)]
fun test_do_init_restrict_must_be_more_restrictive() {
    let (mut scenario, registry, mut account, clock) = start();
    let key1 = b"restrict_dep_only".to_string();
    let key2 = b"restrict_additive_again".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_restrict(
        &mut account,
        &registry,
        key1,
        package_name,
        package::dep_only_policy(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );
    let (_, mut executable1) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key1,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable1,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable1);

    stage_restrict(
        &mut account,
        &registry,
        key2,
        package_name,
        package::additive_policy(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );
    let (_, mut executable2) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key2,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable2,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable2);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = intents::EWrongAccount)]
fun test_do_init_upgrade_wrong_account_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let mut account2 = new_account_for_testing(&registry, scenario.ctx());
    let key = b"wrong_account_upgrade".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_upgrade_and_commit(
        &mut account2,
        &registry,
        key,
        package_name,
        b"digest-v2",
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account2.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    let ticket = pkg_upgrade::do_init_upgrade<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        &clock,
        PackageUpgradeIntent {},
    );

    destroy(ticket);
    destroy(executable);
    destroy(account2);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = intents::EWrongAccount)]
fun test_do_init_restrict_wrong_account_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let mut account2 = new_account_for_testing(&registry, scenario.ctx());
    let key = b"wrong_account_restrict".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_restrict(
        &mut account2,
        &registry,
        key,
        package_name,
        package::additive_policy(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account2.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );

    destroy(executable);
    destroy(account2);
    end(scenario, registry, account, clock);
}

// === do_init_lock_upgrade_cap tests ===

fun stage_lock_upgrade_cap(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    package_name: String,
    delay_ms: u64,
    resource_name: String,
    expected_cap_id: ID,
    execution_time: u64,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let params = intents::new_params(
        key,
        b"Lock upgrade cap".to_string(),
        vector[execution_time],
        expiration_time,
        clock,
        ctx,
    );

    account.build_intent!(
        registry,
        params,
        Outcome {},
        version::current(),
        PackageUpgradeIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&package_name);
            vector::append(&mut action_data, bcs::to_bytes(&delay_ms));
            vector::append(&mut action_data, bcs::to_bytes(&resource_name));
            vector::append(&mut action_data, bcs::to_bytes(&expected_cap_id.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::lock_upgrade_cap_marker(),
                action_data,
                iw,
            );
        },
    );
}

#[test]
fun test_do_init_lock_upgrade_cap_happy_path() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"lock_cap_governed".to_string();
    let package_name = b"govex_core".to_string();
    let delay_ms = 1_000u64;

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    let expected_cap_id = object::id(&cap);
    let resource_name = RESOURCE_NAME.to_string();

    stage_lock_upgrade_cap(
        &mut account,
        &registry,
        key,
        package_name,
        delay_ms,
        resource_name,
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    executable_resources::provide_object_for_testing<UpgradeCap, Outcome>(
        &mut executable,
        RESOURCE_NAME.to_string(),
        cap,
        scenario.ctx(),
    );

    pkg_upgrade::do_init_lock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    assert!(pkg_upgrade::has_cap(&account, package_name));
    assert!(pkg_upgrade::get_time_delay(&account, &registry, package_name) == delay_ms);
    assert!(pkg_upgrade::get_package_addr(&account, &registry, package_name) == @0x1);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::ELockAlreadyExists)]
fun test_do_init_lock_upgrade_cap_double_lock_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"lock_cap_governed_dup".to_string();
    let package_name = b"govex_core".to_string();

    // First lock via direct Auth
    let cap1 = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap1, package_name, 0);

    // Second lock via governed action — should abort
    let cap2 = create_upgrade_cap(@0x2, scenario.ctx());
    let expected_cap_id = object::id(&cap2);

    stage_lock_upgrade_cap(
        &mut account,
        &registry,
        key,
        package_name,
        0,
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    executable_resources::provide_object_for_testing<UpgradeCap, Outcome>(
        &mut executable,
        RESOURCE_NAME.to_string(),
        cap2,
        scenario.ctx(),
    );

    pkg_upgrade::do_init_lock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EEmptyPackageName)]
fun test_do_init_lock_upgrade_cap_empty_name_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"lock_cap_empty_name".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    let expected_cap_id = object::id(&cap);

    stage_lock_upgrade_cap(
        &mut account,
        &registry,
        key,
        b"".to_string(),
        0,
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    executable_resources::provide_object_for_testing<UpgradeCap, Outcome>(
        &mut executable,
        RESOURCE_NAME.to_string(),
        cap,
        scenario.ctx(),
    );

    pkg_upgrade::do_init_lock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock);
}

// === do_init_unlock_upgrade_cap tests ===

fun stage_unlock_upgrade_cap(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    package_name: String,
    resource_name: String,
    expected_cap_id: ID,
    execution_time: u64,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let params = intents::new_params(
        key,
        b"Unlock upgrade cap".to_string(),
        vector[execution_time],
        expiration_time,
        clock,
        ctx,
    );

    account.build_intent!(
        registry,
        params,
        Outcome {},
        version::current(),
        PackageUpgradeIntent {},
        ctx,
        |intent, iw| {
            let mut action_data = bcs::to_bytes(&package_name);
            vector::append(&mut action_data, bcs::to_bytes(&resource_name));
            vector::append(&mut action_data, bcs::to_bytes(&expected_cap_id.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::unlock_upgrade_cap_marker(),
                action_data,
                iw,
            );
        },
    );
}

#[test]
fun test_do_init_unlock_upgrade_cap_happy_path() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"unlock_cap".to_string();
    let package_name = b"govex_core".to_string();

    // Lock a cap first
    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 1_000);
    assert!(pkg_upgrade::has_cap(&account, package_name));
    assert!(pkg_upgrade::is_package_managed(&account, &registry, @0x1));
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    // Stage unlock
    stage_unlock_upgrade_cap(
        &mut account,
        &registry,
        key,
        package_name,
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    // Execute unlock
    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_unlock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
        scenario.ctx(),
    );
    let unlocked_cap = executable_resources::take_object_for_testing<UpgradeCap, Outcome>(
        &mut executable,
        RESOURCE_NAME.to_string(),
    );
    assert!(object::id(&unlocked_cap) == expected_cap_id);
    assert!(unlocked_cap.package().to_address() == @0x1);
    package::make_immutable(unlocked_cap);
    account.confirm_execution(executable);

    // Verify cap removed, index cleaned up
    assert!(!pkg_upgrade::has_cap(&account, package_name));
    assert!(!pkg_upgrade::is_package_managed(&account, &registry, @0x1));

    end(scenario, registry, account, clock);
}

#[test]
fun test_unlock_then_relock_upgrade_cap() {
    let (mut scenario, registry, mut account, clock) = start();
    let package_name = b"govex_core".to_string();

    // Lock
    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 500);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    // Unlock
    let key1 = b"unlock_flow".to_string();
    stage_unlock_upgrade_cap(
        &mut account,
        &registry,
        key1,
        package_name,
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );
    let (_, mut executable1) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key1,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_unlock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable1,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
        scenario.ctx(),
    );
    let unlocked_cap = executable_resources::take_object_for_testing<UpgradeCap, Outcome>(
        &mut executable1,
        RESOURCE_NAME.to_string(),
    );
    account.confirm_execution(executable1);
    assert!(!pkg_upgrade::has_cap(&account, package_name));

    // Re-lock the same cap under the same name after unlocking it to resources.
    lock_cap(&mut account, &registry, unlocked_cap, package_name, 2_000);
    assert!(pkg_upgrade::has_cap(&account, package_name));
    assert!(pkg_upgrade::get_cap_package(&account, &registry, package_name) == @0x1);
    assert!(pkg_upgrade::get_time_delay(&account, &registry, package_name) == 2_000);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EEmptyPackageName)]
fun test_do_init_unlock_upgrade_cap_empty_name_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"unlock_empty".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, b"govex_core".to_string(), 0);
    let expected_cap_id = locked_cap_id(&account, &registry, b"govex_core".to_string());

    stage_unlock_upgrade_cap(
        &mut account,
        &registry,
        key,
        b"".to_string(),
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    pkg_upgrade::do_init_unlock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
        scenario.ctx(),
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = intents::EWrongAccount)]
fun test_do_init_unlock_upgrade_cap_wrong_account_aborts() {
    let (mut scenario, registry, mut account, clock) = start();
    let mut account2 = new_account_for_testing(&registry, scenario.ctx());
    let key = b"wrong_account_unlock".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    stage_unlock_upgrade_cap(
        &mut account2,
        &registry,
        key,
        package_name,
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account2.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    pkg_upgrade::do_init_unlock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
        scenario.ctx(),
    );

    destroy(executable);
    destroy(account2);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EReceiptPackageMismatch)]
fun test_do_init_commit_rejects_receipt_for_wrong_package() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"receipt_mismatch".to_string();
    let package_a = b"govex_core".to_string();
    let package_b = b"govex_aux".to_string();

    let cap_a = create_upgrade_cap(@0x1, scenario.ctx());
    let cap_b = create_upgrade_cap(@0x2, scenario.ctx());
    lock_cap(&mut account, &registry, cap_a, package_a, 0);
    lock_cap(&mut account, &registry, cap_b, package_b, 0);
    let expected_cap_id_a = locked_cap_id(&account, &registry, package_a);
    let expected_cap_id_b = locked_cap_id(&account, &registry, package_b);

    let params = intents::new_params(
        key,
        b"Upgrade A but commit B".to_string(),
        vector[0],
        5_000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &registry,
        params,
        Outcome {},
        version::current(),
        PackageUpgradeIntent {},
        scenario.ctx(),
        |intent, iw| {
            let mut upgrade_data = bcs::to_bytes(&package_a);
            vector::append(&mut upgrade_data, bcs::to_bytes(&b"digest-v2"));
            vector::append(&mut upgrade_data, bcs::to_bytes(&expected_cap_id_a.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_upgrade_marker(),
                upgrade_data,
                iw,
            );

            let mut commit_data = bcs::to_bytes(&package_b);
            vector::append(&mut commit_data, bcs::to_bytes(&expected_cap_id_b.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_commit_marker(),
                commit_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    let ticket = pkg_upgrade::do_init_upgrade<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        &clock,
        PackageUpgradeIntent {},
    );
    let receipt = ticket.test_upgrade();

    pkg_upgrade::do_init_commit<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        receipt,
        PackageUpgradeIntent {},
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeCapIdMismatch)]
fun test_do_init_upgrade_rejects_unexpected_cap_id() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"upgrade_cap_id_mismatch".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);

    stage_upgrade_and_commit(
        &mut account,
        &registry,
        key,
        package_name,
        b"digest-v2",
        object::id_from_address(@0xDEAD),
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    let ticket = pkg_upgrade::do_init_upgrade<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        &clock,
        PackageUpgradeIntent {},
    );

    destroy(ticket);
    destroy(executable);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeCapIdMismatch)]
fun test_do_init_commit_rejects_unexpected_cap_id() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"commit_cap_id_mismatch".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);
    let expected_cap_id = locked_cap_id(&account, &registry, package_name);

    let params = intents::new_params(
        key,
        b"Commit cap-id mismatch".to_string(),
        vector[0],
        5_000,
        &clock,
        scenario.ctx(),
    );

    account.build_intent!(
        &registry,
        params,
        Outcome {},
        version::current(),
        PackageUpgradeIntent {},
        scenario.ctx(),
        |intent, iw| {
            let mut upgrade_data = bcs::to_bytes(&package_name);
            vector::append(&mut upgrade_data, bcs::to_bytes(&b"digest-v2"));
            vector::append(&mut upgrade_data, bcs::to_bytes(&expected_cap_id.to_address()));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_upgrade_marker(),
                upgrade_data,
                iw,
            );

            let mut commit_data = bcs::to_bytes(&package_name);
            vector::append(&mut commit_data, bcs::to_bytes(&@0xDEAD));
            intents::add_typed_action(
                intent,
                pkg_upgrade::package_commit_marker(),
                commit_data,
                iw,
            );
        },
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    let ticket = pkg_upgrade::do_init_upgrade<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        &clock,
        PackageUpgradeIntent {},
    );
    let receipt = ticket.test_upgrade();

    pkg_upgrade::do_init_commit<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        receipt,
        PackageUpgradeIntent {},
    );

    destroy(executable);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeCapIdMismatch)]
fun test_do_init_restrict_rejects_unexpected_cap_id() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"restrict_cap_id_mismatch".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);

    stage_restrict(
        &mut account,
        &registry,
        key,
        package_name,
        package::additive_policy(),
        object::id_from_address(@0xDEAD),
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    pkg_upgrade::do_init_restrict<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );

    destroy(executable);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EInvalidPackageAddress)]
fun test_do_init_lock_upgrade_cap_rejects_zero_package_addr() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"lock_zero_package_addr".to_string();

    let cap = create_upgrade_cap(@0x0, scenario.ctx());
    let expected_cap_id = object::id(&cap);

    stage_lock_upgrade_cap(
        &mut account,
        &registry,
        key,
        b"zero_pkg".to_string(),
        0,
        RESOURCE_NAME.to_string(),
        expected_cap_id,
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    executable_resources::provide_object_for_testing<UpgradeCap, Outcome>(
        &mut executable,
        RESOURCE_NAME.to_string(),
        cap,
        scenario.ctx(),
    );

    pkg_upgrade::do_init_lock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );

    destroy(executable);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeCapIdMismatch)]
fun test_do_init_lock_upgrade_cap_rejects_unexpected_cap_id() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"lock_cap_id_mismatch".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());

    stage_lock_upgrade_cap(
        &mut account,
        &registry,
        key,
        b"govex_core".to_string(),
        0,
        RESOURCE_NAME.to_string(),
        object::id_from_address(@0xDEAD),
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );
    executable_resources::provide_object_for_testing<UpgradeCap, Outcome>(
        &mut executable,
        RESOURCE_NAME.to_string(),
        cap,
        scenario.ctx(),
    );

    pkg_upgrade::do_init_lock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
    );

    destroy(executable);
    end(scenario, registry, account, clock);
}

#[test]
#[expected_failure(abort_code = pkg_upgrade::EUpgradeCapIdMismatch)]
fun test_do_init_unlock_upgrade_cap_rejects_unexpected_cap_id() {
    let (mut scenario, registry, mut account, clock) = start();
    let key = b"unlock_cap_id_mismatch".to_string();
    let package_name = b"govex_core".to_string();

    let cap = create_upgrade_cap(@0x1, scenario.ctx());
    lock_cap(&mut account, &registry, cap, package_name, 0);

    stage_unlock_upgrade_cap(
        &mut account,
        &registry,
        key,
        package_name,
        RESOURCE_NAME.to_string(),
        object::id_from_address(@0xDEAD),
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );

    let (_, mut executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness {},
        scenario.ctx(),
    );

    pkg_upgrade::do_init_unlock_upgrade_cap<Outcome, PackageUpgradeIntent>(
        &mut executable,
        &mut account,
        &registry,
        PackageUpgradeIntent {},
        scenario.ctx(),
    );

    destroy(executable);
    end(scenario, registry, account, clock);
}
