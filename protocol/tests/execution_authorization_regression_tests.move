#[test_only]
module account_protocol::execution_authorization_regression_tests;

use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intents;
use account_protocol::metadata;
use account_protocol::package_registry::{
    Self as package_registry,
    PackageAdminCap,
    PackageRegistry,
};
use account_protocol::version;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};
use sui::test_utils::destroy;

const OWNER: address = @0xCAFE;

public struct Witness() has drop;
public struct DummyIntent() has drop;
public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}
public struct ProbeAction has drop {}
public struct ExecutionProgressWitness has drop {}

fun end(
    scenario: Scenario,
    registry: PackageRegistry,
    account: Account,
    clock: Clock,
    cap: PackageAdminCap,
) {
    destroy(registry);
    destroy(account);
    destroy(clock);
    destroy(cap);
    ts::end(scenario);
}

#[test, expected_failure(abort_code = 2, location = account_protocol::deps)]
fun test_execution_authorization_rechecks_policy_after_executable_created() {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    account::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    let registry = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();

    let deps = deps::new_with_level(&registry, deps::auth_level_whitelist());
    let mut account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );

    let dep_names = account::dep_names_mut(&mut account);
    dep_names.insert(b"AccountProtocol".to_string(), @account_protocol);
    deps::add_dep_no_auth_check(
        account::account_deps_mut(&mut account),
        @account_protocol,
        b"AccountProtocol".to_string(),
        1,
    );

    let clock = clock::create_for_testing(scenario.ctx());
    let key = b"policy_recheck".to_string();
    let params = intents::new_params(
        key,
        b"Policy recheck".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );

    let mut intent = account.create_intent(
        &registry,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    intents::add_action_spec(
        &mut intent,
        ProbeAction {},
        vector[],
        DummyIntent(),
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    let (_, executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    let removed = deps::remove_dep(account::account_deps_mut(&mut account), @account_protocol);
    let removed_name = deps::dep_name(&removed);
    account::dep_names_mut(&mut account).remove(&removed_name);

    account::assert_execution_authorized(
        &account,
        &registry,
        &executable,
        ExecutionProgressWitness {},
    );
    account.confirm_execution(executable);

    end(scenario, registry, account, clock, cap);
}

/// WHITELIST mode must reject staging when the action's package is neither in
/// the global registry nor in the per-account deps. Guards against the gap
/// where WHITELIST's staging-time revalidation is skipped.
#[test, expected_failure(abort_code = 20, location = account_protocol::account)]
fun test_whitelist_rejects_staging_when_action_package_deauthorized() {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    account::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    let registry = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();

    let deps = deps::new_with_level(&registry, deps::auth_level_whitelist());
    let mut account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );

    // Registry is empty. Authorize @account_protocol via per-account deps so
    // create_intent's version_witness check passes; we'll revoke it before staging.
    let dep_names = account::dep_names_mut(&mut account);
    dep_names.insert(b"AccountProtocol".to_string(), @account_protocol);
    deps::add_dep_no_auth_check(
        account::account_deps_mut(&mut account),
        @account_protocol,
        b"AccountProtocol".to_string(),
        1,
    );

    let clock = clock::create_for_testing(scenario.ctx());
    let params = intents::new_params(
        b"stage_unauthorized".to_string(),
        b"Staging should abort after dep removed".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent = account.create_intent(
        &registry,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    intents::add_action_spec(
        &mut intent,
        ProbeAction {},
        vector[],
        DummyIntent(),
    );

    // Revoke @account_protocol before staging. The action_spec's package_addr
    // is now unauthorized by both the (empty) registry and the per-account deps.
    let removed = deps::remove_dep(account::account_deps_mut(&mut account), @account_protocol);
    let removed_name = deps::dep_name(&removed);
    account::dep_names_mut(&mut account).remove(&removed_name);

    // Expected abort: EActionPackageNotAuthorized (20) in account_protocol::account.
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    end(scenario, registry, account, clock, cap);
}

/// `create_executable` must re-validate package authorization. If the action's
/// package is deauthorized between staging and execution, executable creation
/// itself must abort — not merely a downstream `assert_execution_authorized`.
#[test, expected_failure(abort_code = 20, location = account_protocol::account)]
fun test_create_executable_rejects_when_action_package_deauthorized_post_staging() {
    let mut scenario = ts::begin(OWNER);
    package_registry::init_for_testing(scenario.ctx());
    account::init_for_testing(scenario.ctx());

    scenario.next_tx(OWNER);
    let registry = scenario.take_shared<PackageRegistry>();
    let cap = scenario.take_from_sender<PackageAdminCap>();

    let deps = deps::new_with_level(&registry, deps::auth_level_whitelist());
    let mut account = account::new(
        Config {},
        metadata::empty(),
        deps,
        Witness(),
        scenario.ctx(),
    );

    let dep_names = account::dep_names_mut(&mut account);
    dep_names.insert(b"AccountProtocol".to_string(), @account_protocol);
    deps::add_dep_no_auth_check(
        account::account_deps_mut(&mut account),
        @account_protocol,
        b"AccountProtocol".to_string(),
        1,
    );

    let clock = clock::create_for_testing(scenario.ctx());
    let key = b"exec_after_revoke".to_string();
    let params = intents::new_params(
        key,
        b"Create executable should fail after revoke".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );
    let mut intent = account.create_intent(
        &registry,
        params,
        Outcome {},
        version::current(),
        DummyIntent(),
        scenario.ctx(),
    );
    intents::add_action_spec(
        &mut intent,
        ProbeAction {},
        vector[],
        DummyIntent(),
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    // Revoke between staging and create_executable. The hard authorization
    // boundary is executable creation — verify it aborts before producing the
    // Executable (not only at assert_execution_authorized).
    let removed = deps::remove_dep(account::account_deps_mut(&mut account), @account_protocol);
    let removed_name = deps::dep_name(&removed);
    account::dep_names_mut(&mut account).remove(&removed_name);

    let (_, executable) = account.create_executable<Config, Outcome, Witness>(
        &registry,
        key,
        &clock,
        Witness(),
        scenario.ctx(),
    );

    // Unreachable
    account.confirm_execution(executable);
    end(scenario, registry, account, clock, cap);
}
