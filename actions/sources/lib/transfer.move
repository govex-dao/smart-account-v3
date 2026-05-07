// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This module defines apis to transfer assets owned or managed by the account.
/// The intents can implement transfers for any action type (e.g. see owned or vault).

module account_actions::transfer;

public struct ExecutionProgressWitness has drop {}

use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::bcs;
use sui::event;
use sui::object::{Self, ID};

// === Errors ===

const EUnsupportedActionVersion: u64 = 0;
const EEmptyResourceName: u64 = 1;

// === Events ===

/// Emitted when an object is transferred to a recipient (execution)
public struct ObjectTransferred has copy, drop {
    object_id: ID,
    object_type: TypeName,
    recipient: address,
    resource_name: String,
}

/// Emitted when an object is transferred to the transaction sender (execution)
public struct ObjectTransferredToSender has copy, drop {
    object_id: ID,
    object_type: TypeName,
    sender: address,
    resource_name: String,
}

/// Emitted when a coin is transferred to a recipient (execution)
public struct CoinTransferred has copy, drop {
    coin_type: TypeName,
    amount: u64,
    recipient: address,
    resource_name: String,
}

/// Emitted when a coin is transferred to the transaction sender (execution)
public struct CoinTransferredToSender has copy, drop {
    coin_type: TypeName,
    amount: u64,
    sender: address,
    resource_name: String,
}

// === Action Type Markers ===
// CoinType is encoded in coin-related markers to prevent executor from changing coin type

/// Transfer object ownership
/// T is encoded in the marker to prevent executor from substituting a different object type
public struct TransferObject<phantom T> has drop {}
/// Transfer object to transaction sender
/// T is encoded in the marker to prevent executor from substituting a different object type
public struct TransferToSender<phantom T> has drop {}
/// Transfer coin to recipient (uses take_coin key format)
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct TransferCoin<phantom CoinType> has drop {}
/// Transfer coin to transaction sender (uses take_coin key format)
/// CoinType is encoded in the marker to prevent executor from changing coin type
public struct TransferCoinToSender<phantom CoinType> has drop {}

// === Factory Functions ===

/// Create a TransferObject action type marker
public(package) fun transfer_object<T>(): TransferObject<T> { TransferObject {} }

/// Create a TransferToSender action type marker
public(package) fun transfer_to_sender<T>(): TransferToSender<T> { TransferToSender {} }

/// Create a TransferCoin action type marker
public(package) fun transfer_coin<CoinType>(): TransferCoin<CoinType> { TransferCoin {} }

/// Create a TransferCoinToSender action type marker
public(package) fun transfer_coin_to_sender<CoinType>(): TransferCoinToSender<CoinType> {
    TransferCoinToSender {}
}

// === Public functions ===

/// Processes a TransferAction and transfers an object to a recipient.
/// DETERMINISTIC: Takes object from executable_resources (from previous action), NOT from PTB!
/// The resource_name in ActionSpec tells us which resource to take.
public fun do_init_transfer<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<TransferObject<T>>(action_spec);

    // T is encoded in the marker and enforced by the typed increment below.

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // ActionSpec contains: recipient, resource_name (where to take object from)
    let mut reader = bcs::new(*action_data);
    let recipient = bcs::peel_address(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(resource_name.length() > 0, EEmptyResourceName);

    // Take object from executable_resources (deterministic - from previous action!)
    let object: T = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    event::emit(ObjectTransferred {
        object_id: object::id(&object),
        object_type: type_name::get<T>(),
        recipient,
        resource_name,
    });

    transfer::public_transfer(object, recipient);
    executable::increment_action_idx<_, TransferObject<T>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Processes a TransferToSenderAction and transfers an object to the transaction sender
/// DETERMINISTIC: Takes object from executable_resources (from previous action), NOT from PTB!
/// The resource_name in ActionSpec tells us which resource to take.
public fun do_init_transfer_to_sender<Outcome: store, T: key + store, IW: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<TransferToSender<T>>(action_spec);

    // T is encoded in the marker and enforced by the typed increment below.

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // ActionSpec contains: resource_name (where to take object from)
    let mut reader = bcs::new(*action_data);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(resource_name.length() > 0, EEmptyResourceName);

    // Take object from executable_resources (deterministic - from previous action!)
    let object: T = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    let sender = tx_context::sender(ctx);

    event::emit(ObjectTransferredToSender {
        object_id: object::id(&object),
        object_type: type_name::get<T>(),
        sender,
        resource_name,
    });

    // Transfer to the transaction sender (the cranker!)
    transfer::public_transfer(object, sender);
    executable::increment_action_idx<_, TransferToSender<T>, _>(executable, registry, ExecutionProgressWitness {});
}

// === Coin Transfer Functions (use take_coin key format) ===

/// Processes a TransferCoinAction and transfers a coin to a recipient.
/// DETERMINISTIC: Takes coin from executable_resources (from previous action), NOT from PTB!
/// Uses take_coin which matches provide_coin key format (from VaultSpend, CurrencyMint, etc.)
public fun do_init_transfer_coin<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<TransferCoin<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // ActionSpec contains: recipient, resource_name (where to take coin from)
    let mut reader = bcs::new(*action_data);
    let recipient = bcs::peel_address(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(resource_name.length() > 0, EEmptyResourceName);

    // Take coin from executable_resources using take_coin (matches provide_coin key!)
    let coin: sui::coin::Coin<CoinType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    event::emit(CoinTransferred {
        coin_type: type_name::get<CoinType>(),
        amount: coin.value(),
        recipient,
        resource_name,
    });

    transfer::public_transfer(coin, recipient);
    executable::increment_action_idx<_, TransferCoin<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}

/// Processes a TransferCoinToSenderAction and transfers a coin to the transaction sender.
/// DETERMINISTIC: Takes coin from executable_resources (from previous action), NOT from PTB!
/// Uses take_coin which matches provide_coin key format (from VaultSpend, CurrencyMint, etc.)
public fun do_init_transfer_coin_to_sender<Outcome: store, CoinType, IW: drop>(
    executable: &mut Executable<Outcome>,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    // Get BCS bytes from ActionSpec
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<TransferCoinToSender<CoinType>>(action_spec);

    let action_data = intents::action_spec_data(action_spec);

    // Check version before deserialization
    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    // Create BCS reader and deserialize
    // ActionSpec contains: resource_name (where to take coin from)
    let mut reader = bcs::new(*action_data);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));

    // Validate all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(resource_name.length() > 0, EEmptyResourceName);

    // Take coin from executable_resources using take_coin (matches provide_coin key!)
    let coin: sui::coin::Coin<CoinType> = executable_resources::take_coin(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );

    let sender = tx_context::sender(ctx);

    event::emit(CoinTransferredToSender {
        coin_type: type_name::get<CoinType>(),
        amount: coin.value(),
        sender,
        resource_name,
    });

    // Transfer to the transaction sender (the cranker!)
    transfer::public_transfer(coin, sender);
    executable::increment_action_idx<_, TransferCoinToSender<CoinType>, _>(executable, registry, ExecutionProgressWitness {});
}
