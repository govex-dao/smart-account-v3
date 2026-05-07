// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This is the core module managing Intents.
/// It provides the interface to create and execute intents which is used in the `account` module.
/// In the new design, there is no locking - multiple intents can reference the same objects.
/// Conflicts are resolved naturally: if coinA is withdrawn by intent1, intent2 will fail when it tries.

module account_protocol::intents;

use std::bcs;
use std::string::String;
use std::type_name::{Self, TypeName};
use std::vector;
use sui::address;
use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::dynamic_field;
use sui::hex;
use sui::object;
use account_protocol::constants;

// === Imports ===

// === Aliases ===

use fun dynamic_field::add as UID.df_add;
use fun dynamic_field::borrow as UID.df_borrow;
use fun dynamic_field::remove as UID.df_remove;
// Type-based action system - no string descriptors

// === Errors ===

const EIntentNotFound: u64 = 0;
const ENoExecutionTime: u64 = 3;
const EExecutionTimesNotAscending: u64 = 4;
const EKeyAlreadyExists: u64 = 6;
const EWrongAccount: u64 = 7;
const EWrongWitness: u64 = 8;
const ESingleExecution: u64 = 9;
const EUnsupportedActionVersion: u64 = 11;
const EActionDataTooLarge: u64 = 12;
const EExecutionTimeAfterExpiration: u64 = 13;
const EZeroExpirationTime: u64 = 14;
const EActionsNotProcessed: u64 = 15;

// === Structs ===

/// A blueprint for a single action within an intent.
public struct ActionSpec has copy, drop, store {
    version: u8, // Version byte for forward compatibility
    action_type: TypeName, // The type of the action struct
    action_data: vector<u8>, // The BCS-serialized action struct
}

/// Parent struct protecting the intents
public struct Intents has store {
    // map of intents: key -> Intent<Outcome>
    inner: Bag,
}

/// Non-storable intent builder returned by account::create_intent.
///
/// The wrapped Intent is the eventual stored representation, but callers can
/// only hold it through this no-ability wrapper until account::insert_intent*
/// consumes it. That preserves the invariant that creation_time is from the
/// same transaction that stages the intent.
public struct PendingIntent<Outcome> {
    inner: Intent<Outcome>,
}

/// Child struct, intent owning a sequence of actions requested to be executed
/// Outcome is a custom struct depending on the config
public struct Intent<Outcome> has store {
    // type of the intent, checked against the witness to ensure correct execution
    type_: TypeName,
    // name of the intent, serves as a key, should be unique
    key: String,
    // what this intent aims to do, for informational purpose
    description: String,
    // address of the account that created the intent
    account: address,
    // address of the user that created the intent
    creator: address,
    // timestamp of the intent creation
    creation_time: u64,
    // proposer can add a timestamp_ms before which the intent can't be executed
    // can be used to schedule actions via a backend
    // recurring intents can be executed at these times
    execution_times: vector<u64>,
    // the intent can be deleted from this timestamp
    expiration_time: u64,
    // Structured action specifications for type-safe routing (single source of truth)
    action_specs: vector<ActionSpec>,
    // Generic struct storing vote related data, depends on the config
    outcome: Outcome,
}

/// Wrapping actions from an intent that expired or has been executed.
/// Does NOT have `drop` — callers must explicitly consume via destroy_expired()
/// to prevent silently bypassing module-specific cleanup handlers.
public struct Expired {
    // address of the account that created the intent
    account: address,
    // key of the intent that was destroyed
    key: String,
    // action specs that expired or were executed
    action_specs: vector<ActionSpec>,
    // Track which actions were executed for proper destruction
    executed_actions: vector<bool>,
    // Number of scheduled executions that were NOT completed.
    // 0 = all rounds finished, >0 = some/all rounds remain.
    // Config modules can use this to distinguish "fully done" from
    // "partially done" from "never started" for recurring intents.
    remaining_executions: u64,
}

/// Params of an intent to reduce boilerplate.
///
/// `key` only — no `store`/`copy`/`drop`. External callers cannot persist a
/// `Params` across transactions: PTB `TransferObjects` requires `store`,
/// `dynamic_field::add` requires `Value: store`, and an unused non-`drop`
/// result aborts the transaction. Combined with this module exposing exactly
/// one `Params`-by-value consumer (`new_intent`, which deletes the UID), every
/// successfully-committed `Params` is consumed in the same transaction it was
/// created in — so `creation_time` reflects the staging block's timestamp and
/// multisig time-band reaction windows cannot be bypassed by pre-mining.
///
/// This invariant is API-level, not ability-level: the defining module could
/// still introduce a module-private transfer / share / freeze / UID-stash
/// helper that breaks it. Any new `Params`-consuming helper in this module
/// must preserve the same-transaction consumption property.
public struct Params has key {
    id: UID,
}
/// Fields are a df so it intents can be improved in the future
public struct ParamsFieldsV1 has copy, drop, store {
    key: String,
    description: String,
    creation_time: u64,
    execution_times: vector<u64>,
    expiration_time: u64,
}

// === Public functions ===

/// Create a new ActionSpec from an action type marker.
///
/// The marker value proves that the caller went through the action module's
/// constructor instead of supplying an arbitrary TypeName.
public fun new_action_spec<T: drop>(
    _action_type_witness: T,
    action_data: vector<u8>,
    version: u8,
): ActionSpec {
    assert!(version == constants::current_action_version(), EUnsupportedActionVersion);
    assert!(action_data.length() <= constants::max_action_data_size(), EActionDataTooLarge);
    ActionSpec {
        version,
        action_type: type_name::with_original_ids<T>(),
        action_data,
    }
}

/// Add an action specification with pre-serialized bytes (serialize-then-destroy pattern)
public fun add_action_spec<Outcome, T: drop, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    _action_type_witness: T,
    action_data_bytes: vector<u8>,
    intent_witness: IW,
) {
    intent.inner.assert_is_witness(intent_witness);

    // Validate action data size to prevent excessively large actions
    assert!(action_data_bytes.length() <= constants::max_action_data_size(), EActionDataTooLarge);

    // Create and store the action spec with BCS-serialized action
    let action_spec = ActionSpec {
        version: constants::current_action_version(),
        action_type: type_name::with_original_ids<T>(),
        action_data: action_data_bytes,
    };
    intent.inner.action_specs.push_back(action_spec);
}

/// Add an already-constructed ActionSpec to intent (for InitActionSpecs conversion)
/// Validates size but doesn't reconstruct - uses existing version
public fun add_existing_action_spec<Outcome, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    action_spec: ActionSpec,
    intent_witness: IW,
) {
    intent.inner.assert_is_witness(intent_witness);

    // Validate version consistent with other constructors
    assert!(action_spec.version == constants::current_action_version(), EUnsupportedActionVersion);

    // Validate action data size
    assert!(action_spec.action_data.length() <= constants::max_action_data_size(), EActionDataTooLarge);

    // Push existing spec directly
    intent.inner.action_specs.push_back(action_spec);
}

public fun new_params(
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Params {
    assert!(!execution_times.is_empty(), ENoExecutionTime);
    assert!(expiration_time > 0, EZeroExpirationTime);
    let mut i = 0;
    while (i < vector::length(&execution_times) - 1) {
        assert!(execution_times[i] <= execution_times[i + 1], EExecutionTimesNotAscending);
        i = i + 1;
    };
    assert!(
        execution_times[execution_times.length() - 1] < expiration_time,
        EExecutionTimeAfterExpiration,
    );

    let fields = ParamsFieldsV1 {
        key,
        description,
        creation_time: clock.timestamp_ms(),
        execution_times,
        expiration_time,
    };
    let mut id = object::new(ctx);
    id.df_add(true, fields);

    Params { id }
}

public fun new_params_with_rand_key(
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Params, String) {
    let key = ctx.fresh_object_address().to_string();
    let params = new_params(key, description, execution_times, expiration_time, clock, ctx);

    (params, key)
}

/// Add a typed action with pre-serialized bytes (serialize-then-destroy pattern)
/// Callers must serialize the action and then explicitly destroy it
public fun add_typed_action<Outcome, T: drop, IW: drop>(
    intent: &mut PendingIntent<Outcome>,
    action_type: T,
    action_data: vector<u8>,
    intent_witness: IW,
) {
    add_action_spec(intent, action_type, action_data, intent_witness);
}

/// Remove the next action spec from the Expired struct.
/// Returns both the ActionSpec and whether it was executed.
/// Use this to properly handle partial execution during cleanup.
public fun remove_action_spec(expired: &mut Expired): (ActionSpec, bool) {
    let executed = expired.executed_actions.pop_back();
    let spec = expired.action_specs.pop_back();
    (spec, executed)
}

/// Get the number of actions in the Expired struct
public fun expired_action_count(expired: &Expired): u64 {
    expired.action_specs.length()
}

/// Explicitly consume an Expired struct after all action specs have been processed.
/// Callers that need to clean up managed data (e.g., ProposedConfigKey) should
/// process action specs via remove_action_spec() BEFORE calling this.
/// Aborts if any unprocessed action specs remain.
public fun destroy_expired(expired: Expired) {
    let Expired {
        account: _,
        key: _,
        action_specs,
        executed_actions,
        remaining_executions: _,
    } = expired;
    assert!(action_specs.is_empty(), EActionsNotProcessed);
    assert!(executed_actions.is_empty(), EActionsNotProcessed);
}

/// Drain all remaining action specs and destroy the Expired struct.
/// Use when no per-spec cleanup is needed (e.g., cancellation of intents without managed data).
public fun drain_and_destroy_expired(mut expired: Expired) {
    while (expired.action_specs.length() > 0) {
        expired.action_specs.pop_back();
        expired.executed_actions.pop_back();
    };
    destroy_expired(expired);
}

// === View functions ===

public use fun params_key as Params.key;

public fun params_key(params: &Params): String {
    params.id.df_borrow<_, ParamsFieldsV1>(true).key
}

public use fun params_description as Params.description;

public fun params_description(params: &Params): String {
    params.id.df_borrow<_, ParamsFieldsV1>(true).description
}

public use fun params_creation_time as Params.creation_time;

public fun params_creation_time(params: &Params): u64 {
    params.id.df_borrow<_, ParamsFieldsV1>(true).creation_time
}

public use fun params_execution_times as Params.execution_times;

public fun params_execution_times(params: &Params): vector<u64> {
    params.id.df_borrow<_, ParamsFieldsV1>(true).execution_times
}

public use fun params_expiration_time as Params.expiration_time;

public fun params_expiration_time(params: &Params): u64 {
    params.id.df_borrow<_, ParamsFieldsV1>(true).expiration_time
}

public fun length(intents: &Intents): u64 {
    intents.inner.length()
}

public fun contains(intents: &Intents, key: String): bool {
    intents.inner.contains(key)
}

public fun get<Outcome: store>(intents: &Intents, key: String): &Intent<Outcome> {
    assert!(intents.inner.contains(key), EIntentNotFound);
    intents.inner.borrow(key)
}

public fun get_mut<Outcome: store>(intents: &mut Intents, key: String): &mut Intent<Outcome> {
    assert!(intents.inner.contains(key), EIntentNotFound);
    intents.inner.borrow_mut(key)
}

public fun type_<Outcome>(intent: &Intent<Outcome>): TypeName {
    intent.type_
}

public fun key<Outcome>(intent: &Intent<Outcome>): String {
    intent.key
}

public fun description<Outcome>(intent: &Intent<Outcome>): String {
    intent.description
}

public fun account<Outcome>(intent: &Intent<Outcome>): address {
    intent.account
}

public fun creator<Outcome>(intent: &Intent<Outcome>): address {
    intent.creator
}

public fun creation_time<Outcome>(intent: &Intent<Outcome>): u64 {
    intent.creation_time
}

public fun execution_times<Outcome>(intent: &Intent<Outcome>): vector<u64> {
    intent.execution_times
}

public fun expiration_time<Outcome>(intent: &Intent<Outcome>): u64 {
    intent.expiration_time
}

// Actions are now accessed through action_specs
public fun action_count<Outcome>(intent: &Intent<Outcome>): u64 {
    intent.action_specs.length()
}

public fun outcome<Outcome>(intent: &Intent<Outcome>): &Outcome {
    &intent.outcome
}

public fun outcome_mut<Outcome>(intent: &mut Intent<Outcome>): &mut Outcome {
    &mut intent.outcome
}

public fun action_specs<Outcome>(intent: &Intent<Outcome>): &vector<ActionSpec> {
    &intent.action_specs
}

/// Borrow the stored-shape fields from a non-storable pending intent.
///
/// This is read-only so callers can run config-specific policy checks before
/// staging, without gaining a storable Intent value.
public fun pending_inner<Outcome>(intent: &PendingIntent<Outcome>): &Intent<Outcome> {
    &intent.inner
}

public use fun pending_type as PendingIntent.type_;
public fun pending_type<Outcome>(intent: &PendingIntent<Outcome>): TypeName {
    intent.inner.type_
}

public use fun pending_key as PendingIntent.key;
public fun pending_key<Outcome>(intent: &PendingIntent<Outcome>): String {
    intent.inner.key
}

public use fun pending_description as PendingIntent.description;
public fun pending_description<Outcome>(intent: &PendingIntent<Outcome>): String {
    intent.inner.description
}

public use fun pending_account as PendingIntent.account;
public fun pending_account<Outcome>(intent: &PendingIntent<Outcome>): address {
    intent.inner.account
}

public use fun pending_creator as PendingIntent.creator;
public fun pending_creator<Outcome>(intent: &PendingIntent<Outcome>): address {
    intent.inner.creator
}

public use fun pending_creation_time as PendingIntent.creation_time;
public fun pending_creation_time<Outcome>(intent: &PendingIntent<Outcome>): u64 {
    intent.inner.creation_time
}

public use fun pending_execution_times as PendingIntent.execution_times;
public fun pending_execution_times<Outcome>(intent: &PendingIntent<Outcome>): vector<u64> {
    intent.inner.execution_times
}

public use fun pending_expiration_time as PendingIntent.expiration_time;
public fun pending_expiration_time<Outcome>(intent: &PendingIntent<Outcome>): u64 {
    intent.inner.expiration_time
}

public use fun pending_action_count as PendingIntent.action_count;
public fun pending_action_count<Outcome>(intent: &PendingIntent<Outcome>): u64 {
    intent.inner.action_specs.length()
}

public use fun pending_outcome as PendingIntent.outcome;
public fun pending_outcome<Outcome>(intent: &PendingIntent<Outcome>): &Outcome {
    &intent.inner.outcome
}

public use fun pending_outcome_mut as PendingIntent.outcome_mut;
public fun pending_outcome_mut<Outcome>(intent: &mut PendingIntent<Outcome>): &mut Outcome {
    &mut intent.inner.outcome
}

public use fun pending_action_specs as PendingIntent.action_specs;
public fun pending_action_specs<Outcome>(intent: &PendingIntent<Outcome>): &vector<ActionSpec> {
    &intent.inner.action_specs
}

public use fun pending_assert_is_account as PendingIntent.assert_is_account;
public fun pending_assert_is_account<Outcome>(intent: &PendingIntent<Outcome>, account_addr: address) {
    intent.inner.assert_is_account(account_addr);
}

public use fun pending_assert_is_witness as PendingIntent.assert_is_witness;
public fun pending_assert_is_witness<Outcome, IW: drop>(intent: &PendingIntent<Outcome>, witness: IW) {
    intent.inner.assert_is_witness(witness);
}

public use fun pending_pop_front_execution_time as PendingIntent.pop_front_execution_time;
public fun pending_pop_front_execution_time<Outcome>(intent: &mut PendingIntent<Outcome>): u64 {
    pop_front_execution_time(&mut intent.inner)
}

public fun action_spec_version(action_spec: &ActionSpec): u8 {
    action_spec.version
}

public fun action_spec_type(action_spec: &ActionSpec): TypeName {
    action_spec.action_type
}

public fun action_spec_data(action_spec: &ActionSpec): &vector<u8> {
    &action_spec.action_data
}

/// Extract the package address from an ActionSpec's action_type TypeName.
/// This is used to check if the action's package is authorized.
public fun action_spec_package_addr(action_spec: &ActionSpec): address {
    address::from_bytes(
        hex::decode(action_spec.action_type.address_string().into_bytes()),
    )
}

public use fun expired_account as Expired.account;

public fun expired_account(expired: &Expired): address {
    expired.account
}

public use fun expired_key as Expired.key;

public fun expired_key(expired: &Expired): String {
    expired.key
}

public use fun expired_action_specs as Expired.action_specs;

public fun expired_action_specs(expired: &Expired): &vector<ActionSpec> {
    &expired.action_specs
}

public use fun expired_remaining_executions as Expired.remaining_executions;

/// Number of scheduled execution rounds that were NOT completed.
/// 0 = all rounds finished, >0 = some/all rounds remain.
public fun expired_remaining_executions(expired: &Expired): u64 {
    expired.remaining_executions
}

public fun assert_is_account<Outcome>(intent: &Intent<Outcome>, account_addr: address) {
    assert!(intent.account == account_addr, EWrongAccount);
}

public fun assert_is_witness<Outcome, IW: drop>(intent: &Intent<Outcome>, _: IW) {
    assert!(intent.type_ == type_name::with_original_ids<IW>(), EWrongWitness);
}

public use fun assert_expired_is_account as Expired.assert_is_account;

public fun assert_expired_is_account(expired: &Expired, account_addr: address) {
    assert!(expired.account == account_addr, EWrongAccount);
}

public fun assert_single_execution(params: &Params) {
    assert!(
        params.id.df_borrow<_, ParamsFieldsV1>(true).execution_times.length() == 1,
        ESingleExecution,
    );
}

// === Package functions ===

/// The following functions are only used in the `account` module

public(package) fun empty(ctx: &mut TxContext): Intents {
    Intents { inner: bag::new(ctx) }
}

public(package) fun new_intent<Outcome, IW: drop>(
    params: Params,
    outcome: Outcome,
    account_addr: address,
    _intent_witness: IW,
    ctx: &mut TxContext,
): PendingIntent<Outcome> {
    let Params { mut id } = params;

    let ParamsFieldsV1 {
        key,
        description,
        creation_time,
        execution_times,
        expiration_time,
    } = id.df_remove(true);
    id.delete();

    PendingIntent {
        inner: Intent<Outcome> {
            type_: type_name::with_original_ids<IW>(),
            key,
            description,
            account: account_addr,
            creator: ctx.sender(),
            creation_time,
            execution_times,
            expiration_time,
            action_specs: vector::empty(),
            outcome,
        },
    }
}

public(package) fun finish_pending<Outcome>(intent: PendingIntent<Outcome>): Intent<Outcome> {
    let PendingIntent { inner } = intent;
    inner
}

public(package) fun add_intent<Outcome: store>(intents: &mut Intents, intent: Intent<Outcome>) {
    assert!(!intents.contains(intent.key), EKeyAlreadyExists);
    intents.inner.add(intent.key, intent);
}

public(package) fun remove_intent<Outcome: store>(
    intents: &mut Intents,
    key: String,
): Intent<Outcome> {
    assert!(intents.contains(key), EIntentNotFound);
    intents.inner.remove(key)
}

public(package) fun pop_front_execution_time<Outcome>(intent: &mut Intent<Outcome>): u64 {
    assert!(!intent.execution_times.is_empty(), ENoExecutionTime);
    intent.execution_times.remove(0)
}

/// Removes an intent and returns an Expired struct for cleanup.
/// Outcome must be validated by the config module before destruction.
/// `all_executed`: true if all execution rounds completed (destroy_empty_intent,
/// or delete_expired_intent when execution_times is empty),
/// false if cancelled or expired before completing (cancel_intent,
/// or delete_expired_intent when execution_times is non-empty).
/// `remaining_executions` is captured from the intent's execution_times length,
/// letting config modules distinguish "fully done" / "partially done" / "never started".
public(package) fun destroy_intent<Outcome: store + drop>(
    intents: &mut Intents,
    key: String,
    all_executed: bool,
): Expired {
    let Intent<Outcome> {
        account, mut action_specs, key, execution_times, ..
    } = intents.inner.remove(key);
    let remaining_executions = execution_times.length();
    let num_actions = action_specs.length();
    let mut executed_actions = vector::empty<bool>();
    let mut i = 0;
    while (i < num_actions) {
        vector::push_back(&mut executed_actions, all_executed);
        i = i + 1;
    };

    // Reverse so pop_back() returns actions in original order
    action_specs.reverse();
    executed_actions.reverse();

    Expired { account, key, action_specs, executed_actions, remaining_executions }
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

#[test_only]
use sui::test_utils::{assert_eq, destroy};
#[test_only]
use sui::clock;

#[test_only]
public fun new_intent_for_testing<Outcome, IW: drop>(
    params: Params,
    outcome: Outcome,
    account_addr: address,
    intent_witness: IW,
    ctx: &mut TxContext,
): Intent<Outcome> {
    finish_pending(new_intent(params, outcome, account_addr, intent_witness, ctx))
}

#[test_only]
public fun new_params_unchecked_for_testing(
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Params {
    let fields = ParamsFieldsV1 {
        key,
        description,
        creation_time: clock.timestamp_ms(),
        execution_times,
        expiration_time,
    };
    let mut id = object::new(ctx);
    id.df_add(true, fields);
    Params { id }
}

#[test_only]
public struct TestOutcome has copy, drop, store {}
#[test_only]
public struct TestAction has drop, store {}
#[test_only]
public struct TestActionType has drop {}
#[test_only]
public struct TestActionType2 has drop {}
#[test_only]
public struct TestIntentWitness() has drop;
#[test_only]
public struct WrongWitness() has drop;

#[test_only]
public fun destroy_intent_for_testing<Outcome: store + drop>(intent: Intent<Outcome>) {
    let Intent {
        type_: _,
        key: _,
        description: _,
        account: _,
        creator: _,
        creation_time: _,
        execution_times: _,
        expiration_time: _,
        action_specs: _,
        outcome: _,
    } = intent;
}

#[test]
fun test_new_params() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    assert_eq(params.key(), b"test_key".to_string());
    assert_eq(params.description(), b"test_description".to_string());
    assert_eq(params.execution_times(), vector[1000]);
    assert_eq(params.expiration_time(), 2000);
    assert_eq(params.creation_time(), 0);

    destroy(params);
    destroy(clock);
}

#[test]
fun test_new_params_with_rand_key() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let (params, key) = new_params_with_rand_key(
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    assert_eq(params.key(), key);
    assert_eq(params.description(), b"test_description".to_string());
    assert_eq(params.execution_times(), vector[1000]);
    assert_eq(params.expiration_time(), 2000);

    destroy(params);
    destroy(clock);
}

#[test, expected_failure(abort_code = ENoExecutionTime)]
fun test_new_params_empty_execution_times() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[],
        2000,
        &clock,
        ctx,
    );
    destroy(params);
    destroy(clock);
}

#[test, expected_failure(abort_code = EExecutionTimesNotAscending)]
fun test_new_params_not_ascending_execution_times() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[2000, 1000],
        3000,
        &clock,
        ctx,
    );
    destroy(params);
    destroy(clock);
}

#[test]
fun test_new_intent() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    assert_eq(intent.key(), b"test_key".to_string());
    assert_eq(intent.description(), b"test_description".to_string());
    assert_eq(intent.account(), @0xCAFE);
    assert_eq(intent.creation_time(), clock.timestamp_ms());
    assert_eq(intent.execution_times(), vector[1000]);
    assert_eq(intent.expiration_time(), 2000);
    assert_eq(intent.action_count(), 0);

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test]
fun test_add_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let action_data1 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data1, TestIntentWitness());
    assert_eq(intent.action_count(), 1);

    let action_data2 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data2, TestIntentWitness());
    assert_eq(intent.action_count(), 2);

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test]
fun test_remove_action() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let action_data1 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data1, TestIntentWitness());

    let action_data2 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data2, TestIntentWitness());
    add_intent(&mut intents, finish_pending(intent));

    let mut expired = intents.destroy_intent<TestOutcome>(b"test_key".to_string(), false);
    // Drain all action specs before destroying
    while (expired.expired_action_count() > 0) {
        let (_spec, _executed) = expired.remove_action_spec();
    };
    destroy_expired(expired);

    destroy(intents);
    destroy(clock);
}

#[test]
fun test_remove_action_spec_preserves_order() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    // Add two different action types to distinguish ordering
    let action_data1 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType {}, action_data1, TestIntentWitness());

    let action_data2 = bcs::to_bytes(&TestAction {});
    intent.add_typed_action(TestActionType2 {}, action_data2, TestIntentWitness());

    let type1 = type_name::with_original_ids<TestActionType>();
    let type2 = type_name::with_original_ids<TestActionType2>();

    add_intent(&mut intents, finish_pending(intent));
    let mut expired = intents.destroy_intent<TestOutcome>(b"test_key".to_string(), false);

    // First removal should be the first action added (TestActionType)
    let (spec1, _) = expired.remove_action_spec();
    assert_eq(spec1.action_type, type1);

    // Second removal should be the second action added (TestActionType2)
    let (spec2, _) = expired.remove_action_spec();
    assert_eq(spec2.action_type, type2);

    destroy_expired(expired);
    destroy(intents);
    destroy(clock);
}

#[test]
fun test_empty_intents() {
    let ctx = &mut tx_context::dummy();
    let intents = empty(ctx);

    assert_eq(length(&intents), 0);
    assert!(!contains(&intents, b"test_key".to_string()));

    destroy(intents);
}

#[test]
fun test_add_and_remove_intent() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    add_intent(&mut intents, finish_pending(intent));
    assert_eq(length(&intents), 1);
    assert!(contains(&intents, b"test_key".to_string()));

    let removed_intent = remove_intent<TestOutcome>(&mut intents, b"test_key".to_string());
    assert_eq(length(&intents), 0);
    assert!(!contains(&intents, b"test_key".to_string()));

    destroy(removed_intent);
    destroy(intents);
    destroy(clock);
}

#[test, expected_failure(abort_code = EKeyAlreadyExists)]
fun test_add_duplicate_intent() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut intents = empty(ctx);

    let params1 = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let params2 = new_params(
        b"test_key".to_string(),
        b"test_description2".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent1 = new_intent(
        params1,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let intent2 = new_intent(
        params2,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    add_intent(&mut intents, finish_pending(intent1));
    add_intent(&mut intents, finish_pending(intent2));

    destroy(intents);
    destroy(clock);
}

#[test, expected_failure(abort_code = EIntentNotFound)]
fun test_remove_nonexistent_intent() {
    let ctx = &mut tx_context::dummy();
    let mut intents = empty(ctx);

    let removed_intent = remove_intent<TestOutcome>(&mut intents, b"nonexistent_key".to_string());

    destroy(removed_intent);
    destroy(intents);
}

#[test]
fun test_pop_front_execution_time() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000, 2000, 3000],
        4000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    assert_eq(intent.execution_times(), vector[1000, 2000, 3000]);

    let time1 = pending_pop_front_execution_time(&mut intent);
    assert_eq(time1, 1000);
    assert_eq(intent.execution_times(), vector[2000, 3000]);

    let time2 = pending_pop_front_execution_time(&mut intent);
    assert_eq(time2, 2000);
    assert_eq(intent.execution_times(), vector[3000]);

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test, expected_failure(abort_code = ENoExecutionTime)]
fun test_pop_front_execution_time_empty() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    let _ = pending_pop_front_execution_time(&mut intent);
    let _ = pending_pop_front_execution_time(&mut intent);

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test]
fun test_assert_is_account() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    // Should not abort
    pending_assert_is_account(&intent, @0xCAFE);

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test, expected_failure(abort_code = EWrongAccount)]
fun test_assert_is_account_wrong() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    pending_assert_is_account(&intent, @0xBAD);

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test]
fun test_assert_is_witness() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    // Should not abort
    pending_assert_is_witness(&intent, TestIntentWitness());

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test, expected_failure(abort_code = EWrongWitness)]
fun test_assert_is_witness_wrong() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );

    pending_assert_is_witness(&intent, WrongWitness());

    destroy(finish_pending(intent));
    destroy(clock);
}

#[test]
fun test_assert_single_execution() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    // Should not abort
    assert_single_execution(&params);

    destroy(params);
    destroy(clock);
}

#[test, expected_failure(abort_code = ESingleExecution)]
fun test_assert_single_execution_multiple() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000, 2000],
        3000,
        &clock,
        ctx,
    );

    assert_single_execution(&params);

    destroy(params);
    destroy(clock);
}

#[test]
fun test_remaining_executions_all_done() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );
    intent.add_action_spec(TestActionType {}, vector[1], TestIntentWitness());

    // Simulate execution: pop the only execution time
    let _ = pending_pop_front_execution_time(&mut intent);

    let mut intents = empty(ctx);
    add_intent(&mut intents, finish_pending(intent));

    let expired = intents.destroy_intent<TestOutcome>(b"test_key".to_string(), true);
    // All rounds completed → remaining_executions should be 0
    assert_eq(expired.remaining_executions(), 0);

    drain_and_destroy_expired(expired);
    destroy(intents);
    destroy(clock);
}

#[test]
fun test_remaining_executions_partial() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params_unchecked_for_testing(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000, 2000, 3000],
        4000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );
    intent.add_action_spec(TestActionType {}, vector[1], TestIntentWitness());

    // Simulate one execution round: pop first execution time
    let _ = pending_pop_front_execution_time(&mut intent);
    // 2 rounds remain

    let mut intents = empty(ctx);
    add_intent(&mut intents, finish_pending(intent));

    let expired = intents.destroy_intent<TestOutcome>(b"test_key".to_string(), false);
    // 2 of 3 rounds not completed → remaining_executions should be 2
    assert_eq(expired.remaining_executions(), 2);

    drain_and_destroy_expired(expired);
    destroy(intents);
    destroy(clock);
}

#[test]
fun test_remaining_executions_never_started() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);

    let params = new_params(
        b"test_key".to_string(),
        b"test_description".to_string(),
        vector[1000],
        2000,
        &clock,
        ctx,
    );

    let mut intent = new_intent(
        params,
        TestOutcome {},
        @0xCAFE,
        TestIntentWitness(),
        ctx,
    );
    intent.add_action_spec(TestActionType {}, vector[1], TestIntentWitness());

    // No execution — intent expires without any rounds running
    let mut intents = empty(ctx);
    add_intent(&mut intents, finish_pending(intent));

    let expired = intents.destroy_intent<TestOutcome>(b"test_key".to_string(), false);
    // Never started → remaining_executions should be 1
    assert_eq(expired.remaining_executions(), 1);

    drain_and_destroy_expired(expired);
    destroy(intents);
    destroy(clock);
}
