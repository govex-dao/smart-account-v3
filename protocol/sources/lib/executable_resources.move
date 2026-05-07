// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Minimal resource handling for intent execution
///
/// PATTERN:
/// 1. Create intent (actions are pure data)
/// 2. At execution: attach Bag of resources to Executable
/// 3. Actions take what they need from the Bag
/// 4. Bag must be empty when execution completes
///
/// This is the ONLY resource pattern you need.
module account_protocol::executable_resources;

use account_protocol::executable::{Self as executable, Executable};
use account_protocol::package_registry::PackageRegistry;
use std::string::{Self, String};
use std::type_name;
use sui::bag::{Self, Bag};
use sui::coin::Coin;
use sui::dynamic_field as df;
use sui::object::UID;
use sui::tx_context::TxContext;

// === Errors ===
const EResourceNotFound: u64 = 1;
const EResourcesNotEmpty: u64 = 2;
const EResourceAlreadyExists: u64 = 3;

// === Key for attaching Bag to Executable ===
// BCS-constructible key for attaching the Bag to the Executable UID.
//
// Security: this struct intentionally has a private field so only this module can construct
// a `ResourceBagKey` value. This prevents external packages from bypassing the witness-gated API
// with direct `dynamic_field` + `bag` calls.
public struct ResourceBagKey has copy, drop, store { _priv: bool }

// === Coin Resource Management ===

/// Provision a coin into executable's resource bag
/// Call this before/during execution to provide resources
public fun provide_coin<CoinType, Outcome: store, W: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid_mut(executable);
    let bag = get_or_create_bag(uid, ctx);
    let key = coin_key<CoinType>(name);
    assert!(!bag::contains(bag, key), EResourceAlreadyExists);
    bag::add(bag, key, coin);
}

/// Take a coin from executable's resource bag
/// Actions call this to get resources they need
public fun take_coin<CoinType, Outcome: store, W: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
): Coin<CoinType> {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid_mut(executable);
    let bag = borrow_bag_mut(uid);
    let key = coin_key<CoinType>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}

/// Check if a coin resource exists
public fun has_coin<CoinType, Outcome: store, W: drop>(
    executable: &Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
): bool {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid(executable);
    if (!df::exists_(uid, resource_bag_key())) return false;
    let bag: &Bag = df::borrow(uid, resource_bag_key());
    let key = coin_key<CoinType>(name);
    bag::contains(bag, key)
}

// === Generic Object Resource Management ===

/// Provision an arbitrary object into executable's resource bag
/// Call this before/during execution to provide resources
public fun provide_object<T: key + store, Outcome: store, W: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
    object: T,
    ctx: &mut TxContext,
) {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid_mut(executable);
    let bag = get_or_create_bag(uid, ctx);
    let key = object_key<T>(name);
    assert!(!bag::contains(bag, key), EResourceAlreadyExists);
    bag::add(bag, key, object);
}

/// Take an object from executable's resource bag
/// Actions call this to get resources they need
public fun take_object<T: key + store, Outcome: store, W: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
): T {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid_mut(executable);
    let bag = borrow_bag_mut(uid);
    let key = object_key<T>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}

/// Check if an object resource exists
public fun has_object<T: key + store, Outcome: store, W: drop>(
    executable: &Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
): bool {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid(executable);
    if (!df::exists_(uid, resource_bag_key())) return false;
    let bag: &Bag = df::borrow(uid, resource_bag_key());
    let key = object_key<T>(name);
    bag::contains(bag, key)
}

// === Pure Data Resource Management (store only, no key) ===
// Useful for hot potato receipts and other non-object data

/// Provision pure data into executable's resource bag
/// Use for hot potato receipts that only need `store` ability
public fun provide_data<T: store, Outcome: store, W: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
    data: T,
    ctx: &mut TxContext,
) {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid_mut(executable);
    let bag = get_or_create_bag(uid, ctx);
    let key = data_key<T>(name);
    assert!(!bag::contains(bag, key), EResourceAlreadyExists);
    bag::add(bag, key, data);
}

/// Take pure data from executable's resource bag
/// Use for consuming hot potato receipts
public fun take_data<T: store, Outcome: store, W: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
): T {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid_mut(executable);
    let bag = borrow_bag_mut(uid);
    let key = data_key<T>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}

/// Check if pure data exists
public fun has_data<T: store, Outcome: store, W: drop>(
    executable: &Executable<Outcome>,
    registry: &PackageRegistry,
    witness: W,
    name: String,
): bool {
    executable::assert_current_action_witness(executable, registry, witness);
    let uid = executable::uid(executable);
    if (!df::exists_(uid, resource_bag_key())) return false;
    let bag: &Bag = df::borrow(uid, resource_bag_key());
    let key = data_key<T>(name);
    bag::contains(bag, key)
}

// === Cleanup ===

/// Destroy resource bag (must be empty)
/// Call this after execution completes
public(package) fun destroy_resources<Outcome: store>(executable: &mut Executable<Outcome>) {
    let executable_uid = executable::uid_mut(executable);
    if (!df::exists_(executable_uid, resource_bag_key())) return;
    let bag: Bag = df::remove(executable_uid, resource_bag_key());
    assert!(bag::is_empty(&bag), EResourcesNotEmpty);
    bag::destroy_empty(bag);
}

// === Internal Helpers ===

fun get_or_create_bag(executable_uid: &mut UID, ctx: &mut TxContext): &mut Bag {
    if (!df::exists_(executable_uid, resource_bag_key())) {
        let bag = bag::new(ctx);
        df::add(executable_uid, resource_bag_key(), bag);
    };
    df::borrow_mut(executable_uid, resource_bag_key())
}

fun borrow_bag_mut(executable_uid: &mut UID): &mut Bag {
    assert!(df::exists_(executable_uid, resource_bag_key()), EResourceNotFound);
    df::borrow_mut(executable_uid, resource_bag_key())
}

fun coin_key<CoinType>(name: String): String {
    let mut key = name;
    key.append(string::utf8(b"::coin::"));
    key.append(string::from_ascii(type_name::into_string(type_name::with_original_ids<CoinType>())));
    key
}

fun object_key<T>(name: String): String {
    let mut key = name;
    key.append(string::utf8(b"::object::"));
    key.append(string::from_ascii(type_name::into_string(type_name::with_original_ids<T>())));
    key
}

fun data_key<T>(name: String): String {
    let mut key = name;
    key.append(string::utf8(b"::data::"));
    key.append(string::from_ascii(type_name::into_string(type_name::with_original_ids<T>())));
    key
}

fun resource_bag_key(): ResourceBagKey { ResourceBagKey { _priv: false } }

// === Test Helpers ===

// These bypass witness-gating to keep unit/integration tests ergonomic.
// They are only available under `#[test_only]` and are not part of the production API surface.

#[test_only]
public fun provide_coin_for_testing<CoinType, Outcome: store>(
    executable: &mut Executable<Outcome>,
    name: String,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    let uid = executable::uid_mut(executable);
    let bag = get_or_create_bag(uid, ctx);
    let key = coin_key<CoinType>(name);
    assert!(!bag::contains(bag, key), EResourceAlreadyExists);
    bag::add(bag, key, coin);
}

#[test_only]
public fun take_coin_for_testing<CoinType, Outcome: store>(
    executable: &mut Executable<Outcome>,
    name: String,
): Coin<CoinType> {
    let uid = executable::uid_mut(executable);
    let bag = borrow_bag_mut(uid);
    let key = coin_key<CoinType>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}

#[test_only]
public fun provide_object_for_testing<T: key + store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    name: String,
    object: T,
    ctx: &mut TxContext,
) {
    let uid = executable::uid_mut(executable);
    let bag = get_or_create_bag(uid, ctx);
    let key = object_key<T>(name);
    assert!(!bag::contains(bag, key), EResourceAlreadyExists);
    bag::add(bag, key, object);
}

#[test_only]
public fun take_object_for_testing<T: key + store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    name: String,
): T {
    let uid = executable::uid_mut(executable);
    let bag = borrow_bag_mut(uid);
    let key = object_key<T>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}

#[test_only]
public fun provide_data_for_testing<T: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    name: String,
    data: T,
    ctx: &mut TxContext,
) {
    let uid = executable::uid_mut(executable);
    let bag = get_or_create_bag(uid, ctx);
    let key = data_key<T>(name);
    assert!(!bag::contains(bag, key), EResourceAlreadyExists);
    bag::add(bag, key, data);
}

#[test_only]
public fun take_data_for_testing<T: store, Outcome: store>(
    executable: &mut Executable<Outcome>,
    name: String,
): T {
    let uid = executable::uid_mut(executable);
    let bag = borrow_bag_mut(uid);
    let key = data_key<T>(name);
    assert!(bag::contains(bag, key), EResourceNotFound);
    bag::remove(bag, key)
}
