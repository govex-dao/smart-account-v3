// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Action events module for indexing canonical staged actions.
///
/// Builder-time parameter events are intentionally not externally emitted:
/// public builders can be called with arbitrary context and then discarded.
/// Indexers should treat `IntentActionSpecStaged` as canonical because it is
/// emitted only from `account::insert_intent*` after the exact staged
/// `ActionSpec` vector has passed account/config/dependency validation.
///
/// `IntentActionsStaged` and `ActionParamsStaged` remain as legacy event
/// structs, but their compatibility emitters are no-ops.

module account_protocol::action_events;

use account_protocol::intents::{Self, ActionSpec, Intent};
use std::string::{Self, String};
use sui::event;
use sui::object::ID;
use account_protocol::constants;

// === Source Type Accessors ===

public fun source_launchpad_success(): u8 { constants::source_launchpad_success() }

public fun source_launchpad_failure(): u8 { constants::source_launchpad_failure() }

public fun source_proposal(): u8 { constants::source_proposal() }

public fun source_factory_init(): u8 { constants::source_factory_init() }

// === Events ===

/// Legacy summary event type. Do not treat this as canonical.
public struct IntentActionsStaged has copy, drop {
    /// Source type: 0=launchpad_success, 1=launchpad_failure, 2=proposal, 3=factory_init
    source_type: u8,
    /// Source ID (raise_id or proposal_id or dao_id)
    source_id: ID,
    /// Outcome index (0 for launchpad success, 1 for failure, 0-N for proposal outcomes)
    outcome_index: u64,
    /// Ordered list of action types - index in vector = action_index
    /// e.g., ["0x123::vault::VaultSpend<0x2::sui::SUI>", "0x456::transfer::Transfer"]
    action_types: vector<String>,
}

/// Legacy parameter event type. Do not treat this as canonical.
public struct ActionParamsStaged has copy, drop {
    /// Source type: 0=launchpad_success, 1=launchpad_failure, 2=proposal, 3=factory_init
    source_type: u8,
    /// Source ID (raise_id or proposal_id or dao_id)
    source_id: ID,
    /// Outcome index (0 for launchpad success, 1 for failure, 0-N for proposal outcomes)
    outcome_index: u64,
    /// Position in the action batch (0-indexed)
    action_index: u64,
    /// Full action type including generics
    /// e.g., "0x123::vault::VaultSpend<0x2::sui::SUI>"
    action_type: String,
    /// Parameter types in BCS serialization order
    /// e.g., ["String", "u64", "String"]
    param_types: vector<String>,
    /// Parameter names matching types order
    /// e.g., ["vault_name", "amount", "resource_name"]
    param_names: vector<String>,
    /// Parameter values as strings matching types order
    /// e.g., ["treasury", "1000", "spend_output"]
    param_values: vector<String>,
}

/// Authoritative per-action event emitted by account insertion.
/// Unlike builder-emitted parameter events, this is derived from the exact
/// ActionSpec vector that is inserted into the account's intent store.
public struct IntentActionSpecStaged has copy, drop {
    account_id: ID,
    intent_key: String,
    action_index: u64,
    action_type: String,
    action_version: u8,
    action_data: vector<u8>,
}

// === ParamsBuilder ===

/// Builder to construct params in correct BCS serialization order.
/// Use type-specific add_* functions to ensure correct string representation.
public struct ParamsBuilder has drop {
    types: vector<String>,
    names: vector<String>,
    values: vector<String>,
}

/// Create a new ParamsBuilder
public fun new_builder(): ParamsBuilder {
    ParamsBuilder {
        types: vector[],
        names: vector[],
        values: vector[],
    }
}

/// Add a u64 parameter
public fun add_u64(b: &mut ParamsBuilder, name: vector<u8>, value: u64) {
    b.types.push_back(string::utf8(b"u64"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(u64_to_string(value));
}

/// Add a u128 parameter
public fun add_u128(b: &mut ParamsBuilder, name: vector<u8>, value: u128) {
    b.types.push_back(string::utf8(b"u128"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(u128_to_string(value));
}

/// Add an address parameter
public fun add_address(b: &mut ParamsBuilder, name: vector<u8>, value: address) {
    b.types.push_back(string::utf8(b"address"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(address_to_hex(value));
}

/// Add an ID parameter
public fun add_id(b: &mut ParamsBuilder, name: vector<u8>, value: ID) {
    b.types.push_back(string::utf8(b"ID"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(address_to_hex(sui::object::id_to_address(&value)));
}

/// Add a String parameter (hex-encoded to prevent JSON injection)
public fun add_string(b: &mut ParamsBuilder, name: vector<u8>, value: String) {
    b.types.push_back(string::utf8(b"String"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(bytes_to_hex(value.as_bytes()));
}

/// Add a bool parameter
public fun add_bool(b: &mut ParamsBuilder, name: vector<u8>, value: bool) {
    b.types.push_back(string::utf8(b"bool"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(if (value) string::utf8(b"true") else string::utf8(b"false"));
}

/// Add an Option<u64> parameter
public fun add_option_u64(
    b: &mut ParamsBuilder,
    name: vector<u8>,
    value: std::option::Option<u64>,
) {
    b.types.push_back(string::utf8(b"Option<u64>"));
    b.names.push_back(string::utf8(name));
    b
        .values
        .push_back(if (value.is_some()) u64_to_string(*value.borrow()) else string::utf8(b"null"));
}

/// Add an Option<u128> parameter
public fun add_option_u128(
    b: &mut ParamsBuilder,
    name: vector<u8>,
    value: std::option::Option<u128>,
) {
    b.types.push_back(string::utf8(b"Option<u128>"));
    b.names.push_back(string::utf8(name));
    b
        .values
        .push_back(if (value.is_some()) u128_to_string(*value.borrow()) else string::utf8(b"null"));
}

/// Add an Option<address> parameter
public fun add_option_address(
    b: &mut ParamsBuilder,
    name: vector<u8>,
    value: std::option::Option<address>,
) {
    b.types.push_back(string::utf8(b"Option<address>"));
    b.names.push_back(string::utf8(name));
    b
        .values
        .push_back(if (value.is_some()) address_to_hex(*value.borrow()) else string::utf8(b"null"));
}

/// Add a vector<u8> parameter (as hex string)
public fun add_vector_u8(b: &mut ParamsBuilder, name: vector<u8>, value: &vector<u8>) {
    b.types.push_back(string::utf8(b"vector<u8>"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(bytes_to_hex(value));
}

/// Add u8 parameter
public fun add_u8(b: &mut ParamsBuilder, name: vector<u8>, value: u8) {
    b.types.push_back(string::utf8(b"u8"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(u64_to_string(value as u64));
}

/// Add a vector<String> parameter (as JSON array)
public fun add_vector_string(b: &mut ParamsBuilder, name: vector<u8>, values: &vector<String>) {
    b.types.push_back(string::utf8(b"vector<String>"));
    b.names.push_back(string::utf8(name));
    // Encode each string as hex bytes to avoid JSON injection via quotes/backslashes.
    let mut result = string::utf8(b"[");
    let mut i = 0;
    while (i < values.length()) {
        if (i > 0) { result.append_utf8(b", "); };
        result.append_utf8(b"\"");
        result.append(bytes_to_hex(values.borrow(i).as_bytes()));
        result.append_utf8(b"\"");
        i = i + 1;
    };
    result.append_utf8(b"]");
    b.values.push_back(result);
}

/// Add a vector<address> parameter (as JSON array of hex strings)
public fun add_vector_address(b: &mut ParamsBuilder, name: vector<u8>, values: &vector<address>) {
    b.types.push_back(string::utf8(b"vector<address>"));
    b.names.push_back(string::utf8(name));
    let mut result = string::utf8(b"[");
    let mut i = 0;
    while (i < values.length()) {
        if (i > 0) { result.append_utf8(b", "); };
        result.append_utf8(b"\"");
        result.append(address_to_hex(*values.borrow(i)));
        result.append_utf8(b"\"");
        i = i + 1;
    };
    result.append_utf8(b"]");
    b.values.push_back(result);
}

/// Add Option<vector<address>> parameter
public fun add_option_vector_address(
    b: &mut ParamsBuilder,
    name: vector<u8>,
    value: &Option<vector<address>>,
) {
    b.types.push_back(string::utf8(b"Option<vector<address>>"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(if (value.is_some()) {
        let addresses = value.borrow();
        let mut result = string::utf8(b"{\"some\":[");
        let mut i = 0;
        while (i < addresses.length()) {
            if (i > 0) { result.append_utf8(b", "); };
            result.append_utf8(b"\"");
            result.append(address_to_hex(*addresses.borrow(i)));
            result.append_utf8(b"\"");
            i = i + 1;
        };
        result.append_utf8(b"]}");
        result
    } else {
        string::utf8(b"{\"none\":true}")
    });
}

/// Add Option<String> parameter
public fun add_option_string(b: &mut ParamsBuilder, name: vector<u8>, value: &Option<String>) {
    b.types.push_back(string::utf8(b"Option<String>"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(if (value.is_some()) {
        let mut encoded = string::utf8(b"{\"some_hex\":\"");
        encoded.append(bytes_to_hex(value.borrow().as_bytes()));
        encoded.append_utf8(b"\"}");
        encoded
    } else {
        string::utf8(b"{\"none\":true}")
    });
}

/// Add Option<bool> parameter
public fun add_option_bool(b: &mut ParamsBuilder, name: vector<u8>, value: Option<bool>) {
    b.types.push_back(string::utf8(b"Option<bool>"));
    b.names.push_back(string::utf8(name));
    b.values.push_back(if (value.is_some()) {
        if (*value.borrow()) string::utf8(b"true") else string::utf8(b"false")
    } else {
        string::utf8(b"null")
    });
}

// === Emit Functions ===

/// Legacy compatibility emitter. This intentionally emits nothing because
/// builder values can be fabricated and discarded; indexers should use
/// `IntentActionSpecStaged` for authoritative staged action data.
public fun emit_action_params(
    _builder: ParamsBuilder,
    _source_type: u8,
    _source_id: ID,
    _outcome_index: u64,
    _action_type: String,
    _action_index: u64,
) {}

/// Legacy compatibility emitter. This intentionally emits nothing; use
/// `emit_intent_action_specs` from account insertion for canonical indexing.
public fun emit_intent_actions(
    _source_type: u8,
    _source_id: ID,
    _outcome_index: u64,
    _action_types: vector<String>,
) {}

/// Emit canonical action specs from the actual intent being staged.
public(package) fun emit_intent_action_specs<Outcome>(account_id: ID, intent: &Intent<Outcome>) {
    let specs = intents::action_specs(intent);
    let mut i = 0;
    let len = specs.length();
    while (i < len) {
        let spec = specs.borrow(i);
        event::emit(IntentActionSpecStaged {
            account_id,
            intent_key: intents::key(intent),
            action_index: i,
            action_type: intents::action_spec_type(spec).into_string().to_string(),
            action_version: intents::action_spec_version(spec),
            action_data: *intents::action_spec_data(spec),
        });
        i = i + 1;
    };
}

/// Collect canonical fields from a staged ActionSpec vector for source-specific
/// events emitted by the module that actually stores those specs.
public fun collect_action_spec_fields(
    specs: &vector<ActionSpec>,
): (vector<String>, vector<u8>, vector<vector<u8>>) {
    let mut action_types = vector::empty<String>();
    let mut action_versions = vector::empty<u8>();
    let mut action_data = vector::empty<vector<u8>>();

    let mut i = 0;
    let len = specs.length();
    while (i < len) {
        let spec = specs.borrow(i);
        action_types.push_back(intents::action_spec_type(spec).into_string().to_string());
        action_versions.push_back(intents::action_spec_version(spec));
        action_data.push_back(*intents::action_spec_data(spec));
        i = i + 1;
    };

    (action_types, action_versions, action_data)
}

// === String Conversion Helpers ===

/// Convert u64 to decimal string
fun u64_to_string(value: u64): String {
    if (value == 0) {
        return string::utf8(b"0")
    };

    let mut bytes = vector[];
    let mut n = value;
    while (n > 0) {
        let digit = ((n % 10) as u8) + 48; // ASCII '0' = 48
        bytes.insert(digit, 0);
        n = n / 10;
    };
    string::utf8(bytes)
}

/// Convert u128 to decimal string
fun u128_to_string(value: u128): String {
    if (value == 0) {
        return string::utf8(b"0")
    };

    let mut bytes = vector[];
    let mut n = value;
    while (n > 0) {
        let digit = ((n % 10) as u8) + 48;
        bytes.insert(digit, 0);
        n = n / 10;
    };
    string::utf8(bytes)
}

/// Convert address to hex string with 0x prefix
fun address_to_hex(addr: address): String {
    let bytes = sui::address::to_bytes(addr);
    let hex = sui::hex::encode(bytes);
    let mut result = b"0x";
    result.append(hex);
    string::utf8(result)
}

/// Convert bytes to hex string with 0x prefix
fun bytes_to_hex(bytes: &vector<u8>): String {
    let hex = sui::hex::encode(*bytes);
    let mut result = b"0x";
    result.append(hex);
    string::utf8(result)
}

// === Tests ===

#[test]
fun test_u64_to_string() {
    assert!(u64_to_string(0) == string::utf8(b"0"), 0);
    assert!(u64_to_string(1) == string::utf8(b"1"), 1);
    assert!(u64_to_string(123) == string::utf8(b"123"), 2);
    assert!(u64_to_string(1000000) == string::utf8(b"1000000"), 3);
}

#[test]
fun test_u128_to_string() {
    assert!(u128_to_string(0) == string::utf8(b"0"), 0);
    assert!(u128_to_string(123456789012345678) == string::utf8(b"123456789012345678"), 1);
}

#[test]
fun test_params_builder() {
    let mut builder = new_builder();
    add_u64(&mut builder, b"amount", 1000);
    add_string(&mut builder, b"name", string::utf8(b"treasury"));
    add_bool(&mut builder, b"enabled", true);

    assert!(builder.types.length() == 3, 0);
    assert!(builder.names.length() == 3, 1);
    assert!(builder.values.length() == 3, 2);

    assert!(*builder.types.borrow(0) == string::utf8(b"u64"), 3);
    assert!(*builder.names.borrow(0) == string::utf8(b"amount"), 4);
    assert!(*builder.values.borrow(0) == string::utf8(b"1000"), 5);
}

#[test]
fun test_add_option_vector_address_none() {
    let mut builder = new_builder();
    add_option_vector_address(&mut builder, b"allowed_destinations", &std::option::none());

    assert!(builder.types.length() == 1, 0);
    assert!(builder.names.length() == 1, 1);
    assert!(builder.values.length() == 1, 2);
    assert!(*builder.types.borrow(0) == string::utf8(b"Option<vector<address>>"), 3);
    assert!(*builder.names.borrow(0) == string::utf8(b"allowed_destinations"), 4);
    assert!(*builder.values.borrow(0) == string::utf8(b"{\"none\":true}"), 5);
}

#[test]
fun test_add_option_vector_address_some() {
    let mut builder = new_builder();
    let allowed = std::option::some(vector[@0x1, @0x2]);
    add_option_vector_address(&mut builder, b"allowed_destinations", &allowed);

    let mut expected = string::utf8(b"{\"some\":[\"");
    expected.append(address_to_hex(@0x1));
    expected.append_utf8(b"\", \"");
    expected.append(address_to_hex(@0x2));
    expected.append_utf8(b"\"]}");

    assert!(builder.types.length() == 1, 0);
    assert!(builder.names.length() == 1, 1);
    assert!(builder.values.length() == 1, 2);
    assert!(*builder.values.borrow(0) == expected, 3);
}
