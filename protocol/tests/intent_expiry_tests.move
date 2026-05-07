// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Tests for H3 fix: create_executable must reject expired intents.
///
/// Before the fix, create_executable only checked execution_time but not
/// expiration_time. An expired intent could be executed if no one had
/// deleted it via the janitor cleanup path.
///
/// Zero-expiry legacy intents are intentionally unsupported post-upgrade.
#[test_only]
module account_protocol::intent_expiry_tests;

use account_protocol::account::{Self, Account};
use account_protocol::deps;
use account_protocol::intents;
use account_protocol::metadata;
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use account_protocol::version;
use sui::clock::{Self, Clock};
use sui::test_utils::destroy;

// === Test types ===

public struct Config has copy, drop, store {}
public struct Outcome has copy, drop, store {}
public struct Witness() has drop;
public struct DummyIntent() has drop;

const OWNER: address = @0xCAFE;

// === Helpers ===

fun setup(ctx: &mut TxContext): (PackageRegistry, Account, Clock) {
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new(&registry);
    let account = account::new(Config {}, metadata::empty(), deps, Witness(), ctx);
    let clock = clock::create_for_testing(ctx);
    (registry, account, clock)
}

fun teardown(registry: PackageRegistry, account: Account, clock: Clock) {
    destroy(registry);
    destroy(account);
    destroy(clock);
}

// =============================================================================
// Test 1: create_executable succeeds when intent is NOT expired
// =============================================================================

#[test]
fun test_create_executable_succeeds_before_expiry() {
    let ctx = &mut tx_context::dummy();
    let (registry, mut account, clock) = setup(ctx);
    let key = b"test_intent".to_string();

    // execution_time=0, expiration_time=1000 — clock is at 0, well before expiry
    let params = intents::new_params(key, b"test".to_string(), vector[0], 1000, &clock, ctx);
    let intent = account.create_intent(
        &registry, params, Outcome {}, version::current(), DummyIntent(), ctx,
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    let (_, executable) = account.create_executable<Config, Outcome, Witness>(
        &registry, key, &clock, Witness(), ctx,
    );

    account.confirm_execution(executable);
    teardown(registry, account, clock);
}

// =============================================================================
// Test 2: create_executable aborts when intent IS expired (the H3 fix)
// =============================================================================

#[test, expected_failure(abort_code = account::EIntentExpired)]
fun test_create_executable_aborts_when_expired() {
    let ctx = &mut tx_context::dummy();
    let (registry, mut account, mut clock) = setup(ctx);
    let key = b"test_intent".to_string();

    // execution_time=0, expiration_time=100
    let params = intents::new_params(key, b"test".to_string(), vector[0], 100, &clock, ctx);
    let intent = account.create_intent(
        &registry, params, Outcome {}, version::current(), DummyIntent(), ctx,
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    // Advance clock past expiration
    clock::set_for_testing(&mut clock, 100);

    // Should abort with EIntentExpired because clock >= expiration_time
    let (_, executable) = account.create_executable<Config, Outcome, Witness>(
        &registry, key, &clock, Witness(), ctx,
    );

    // Unreachable
    account.confirm_execution(executable);
    teardown(registry, account, clock);
}

// =============================================================================
// Test 3: create_executable succeeds at time just before expiry
// =============================================================================

#[test]
fun test_create_executable_succeeds_at_boundary() {
    let ctx = &mut tx_context::dummy();
    let (registry, mut account, mut clock) = setup(ctx);
    let key = b"test_intent".to_string();

    // execution_time=50, expiration_time=100
    let params = intents::new_params(key, b"test".to_string(), vector[50], 100, &clock, ctx);
    let intent = account.create_intent(
        &registry, params, Outcome {}, version::current(), DummyIntent(), ctx,
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    // Clock at 99 — past execution_time, before expiration_time
    clock::set_for_testing(&mut clock, 99);

    let (_, executable) = account.create_executable<Config, Outcome, Witness>(
        &registry, key, &clock, Witness(), ctx,
    );

    account.confirm_execution(executable);
    teardown(registry, account, clock);
}

#[test, expected_failure(abort_code = account::EIntentExpired)]
fun test_create_executable_rejects_legacy_zero_expiry_intent() {
    let ctx = &mut tx_context::dummy();
    let (registry, mut account, clock) = setup(ctx);
    let key = b"legacy_zero_expiry".to_string();

    let params = intents::new_params_unchecked_for_testing(
        key,
        b"legacy".to_string(),
        vector[0],
        0,
        &clock,
        ctx,
    );
    let intent = account.create_intent(
        &registry, params, Outcome {}, version::current(), DummyIntent(), ctx,
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());

    let (_, executable) = account.create_executable<Config, Outcome, Witness>(
        &registry, key, &clock, Witness(), ctx,
    );

    account.confirm_execution(executable);
    teardown(registry, account, clock);
}

#[test, expected_failure(abort_code = account::EHasntExpired)]
fun test_delete_expired_intent_rejects_legacy_zero_expiry_intent() {
    let ctx = &mut tx_context::dummy();
    let (registry, mut account, mut clock) = setup(ctx);
    let key = b"legacy_zero_expiry".to_string();

    let params = intents::new_params_unchecked_for_testing(
        key,
        b"legacy".to_string(),
        vector[0],
        0,
        &clock,
        ctx,
    );
    let intent = account.create_intent(
        &registry, params, Outcome {}, version::current(), DummyIntent(), ctx,
    );
    account.insert_intent_unshared(&registry, intent, version::current(), DummyIntent());
    clock::set_for_testing(&mut clock, 100);

    destroy(account.delete_expired_intent<Outcome, Witness>(
        key,
        &clock,
        Witness(),
        ctx,
    ));
    teardown(registry, account, clock);
}
