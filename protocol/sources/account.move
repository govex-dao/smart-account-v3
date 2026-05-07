// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This is the core module managing the account Account.
/// It provides the apis to create, approve and execute intents with actions.
///
/// The flow is as follows:
///   1. An intent is created by stacking actions into it.
///      Actions are pushed from first to last, they must be executed then destroyed in the same order.
///   2. When the intent is resolved (threshold reached, quorum reached, etc), it can be executed.
///      This returns an Executable hot potato constructed from certain fields of the validated Intent.
///      It is directly passed into action functions to enforce account approval for an action to be executed.
///   3. The module that created the intent must destroy all of the actions and the Executable after execution
///      by passing the same witness that was used for instantiation.
///      This prevents the actions or the intent to be stored instead of executed.
///
/// Dependencies can create and manage dynamic fields for an account.
/// They should use custom types as keys to enable access only via the accessors defined.
///
/// Functions related to authentication, intent resolution, state of intents and config for an account type
/// must be called from the module that defines the config of the account.
/// They necessitate a config_witness to ensure the caller is a dependency of the account.
///
/// The rest of the functions manipulating the common state of accounts are only called within this package.

module account_protocol::account;

use account_protocol::action_events;
use account_protocol::deps::{Self, Deps, DepInfo};
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents::{Self, Intents, Intent, PendingIntent, Expired, Params};
use account_protocol::metadata::{Self, Metadata};
use account_protocol::package_registry::{Self as package_registry, PackageRegistry};
use account_protocol::version_witness::{Self as version_witness, VersionWitness};
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::address;
use sui::clock::Clock;
use sui::dynamic_field as df;
use sui::dynamic_object_field as dof;
use sui::hex;
use sui::package;
use sui::table::{Self as table, Table};
use sui::transfer::Receiving;
use sui::vec_map::VecMap;

// === Imports ===

// === Errors ===

const ECantBeRemovedYet: u64 = 1;
const EHasntExpired: u64 = 2;
const ECantBeExecutedYet: u64 = 3;
const EWrongAccount: u64 = 4;
const EActionsRemaining: u64 = 6;
const EManagedDataAlreadyExists: u64 = 7;
const EManagedDataDoesntExist: u64 = 8;
const EManagedAssetAlreadyExists: u64 = 9;
const EManagedAssetDoesntExist: u64 = 10;
const EWrongConfigType: u64 = 15;
const ENotConfigModule: u64 = 16;
const EActionPackageNotAuthorized: u64 = 20;
const EAccountAlreadyInitialized: u64 = 21;
const ERegistryMismatch: u64 = 23;
const EReservedKey: u64 = 24;
const EIntentExpired: u64 = 25;
const EDepNamesMissing: u64 = 26;
const EAlreadyExecuted: u64 = 27;

// === Structs ===

public struct ACCOUNT has drop {}

/// Shared Account object.
/// Config is stored as a dynamic field to allow runtime config migration.
public struct Account has key, store {
    id: UID,
    // arbitrary data that can be proposed and added by members
    // first field is a human readable name to differentiate the multisig accounts
    metadata: Metadata,
    // ids and versions of the packages this account is using
    // idx 0: account_protocol, idx 1: account_actions optionally
    // Note: registry_id is now stored within Deps
    deps: Deps,
    // open intents, key should be a unique descriptive name
    intents: Intents,
    // SECURITY: Set to true when account is shared. Prevents _unshared functions
    // from being called on shared accounts, blocking auth bypass attacks.
    initialized: bool,
}

// === Dynamic Field Keys for Config Storage ===

/// Key for storing config as a dynamic field
public struct ConfigKey has copy, drop, store {}

/// Key for storing config type name (for runtime validation)
public struct ConfigTypeKey has copy, drop, store {}

/// Key for storing the exact config witness type name (prevents same-module type confusion)
public struct ConfigWitnessTypeKey has copy, drop, store {}

// === Reserved Key Guard ===

/// Prevents external packages from using generic managed-data/asset APIs to
/// add, mutate, or remove internal system keys (ConfigKey, ConfigTypeKey,
/// ConfigWitnessTypeKey, AccountDepsKey). These keys are managed exclusively by account internals.
fun assert_not_reserved_key<Key: copy + drop + store>() {
    let key_type = type_name::with_original_ids<Key>();
    assert!(key_type != type_name::with_original_ids<ConfigKey>(), EReservedKey);
    assert!(key_type != type_name::with_original_ids<ConfigTypeKey>(), EReservedKey);
    assert!(key_type != type_name::with_original_ids<ConfigWitnessTypeKey>(), EReservedKey);
    assert!(key_type != type_name::with_original_ids<deps::AccountDepsKey>(), EReservedKey);
    assert!(key_type != type_name::with_original_ids<deps::DepNamesKey>(), EReservedKey);
}

// === Events ===

/// Protected type ensuring provenance, authenticate an address to an account.
public struct Auth {
    // address of the account that created the auth
    account_addr: address,
}

//**************************************************************************************************//
// Public functions                                                                                //
//**************************************************************************************************//

fun init(otw: ACCOUNT, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx); // to create Display objects in the future
}

/// Verifies all actions have been processed and destroys the executable.
/// Called to complete the intent execution.
public fun confirm_execution<Outcome: drop + store>(
    account: &mut Account,
    mut executable: Executable<Outcome>,
) {
    assert!(executable.is_complete(), EActionsRemaining);

    // Clean up resource bag before destroying the UID
    // This ensures no dynamic fields remain attached (required by Sui)
    // Also asserts bag is empty - catches unconsumed hot potatoes
    executable_resources::destroy_resources(&mut executable);

    let intent = executable.destroy_complete();
    intent.assert_is_account(account.addr());

    account.intents.add_intent(intent);
}

/// Destroys an intent if it has no remaining execution (fully executed).
/// Caller must consume the returned Expired via intents::destroy_expired().
/// Requires config witness to prevent bypassing config-module cleanup (e.g. ProposedConfigKey).
public fun destroy_empty_intent<Outcome: store + drop, CW: drop>(
    account: &mut Account,
    key: String,
    config_witness: CW,
    ctx: &mut TxContext,
): Expired {
    assert_is_config_module_witness(account, config_witness);
    assert!(account.intents.get<Outcome>(key).execution_times().is_empty(), ECantBeRemovedYet);
    // all_executed = true: intent completed all executions
    account.intents.destroy_intent<Outcome>(key, true)
}

/// Destroys an intent if it has expired.
/// Caller must consume the returned Expired via intents::destroy_expired().
/// Requires config witness to prevent bypassing config-module cleanup (e.g. ProposedConfigKey).
///
/// Computes `all_executed` from remaining execution_times:
/// - empty → all rounds completed (intent was fully executed but not yet cleaned up)
/// - non-empty → some/all rounds were not executed before expiry
public fun delete_expired_intent<Outcome: store + drop, CW: drop>(
    account: &mut Account,
    key: String,
    clock: &Clock,
    config_witness: CW,
    ctx: &mut TxContext,
): Expired {
    assert_is_config_module_witness(account, config_witness);
    let intent = account.intents.get<Outcome>(key);
    let exp_time = intent.expiration_time();
    // Legacy zero-expiry intents are intentionally unsupported post-upgrade.
    assert!(exp_time > 0, EHasntExpired);
    assert!(clock.timestamp_ms() >= exp_time, EHasntExpired);
    // Compute truthfully: if execution_times is empty, all rounds completed
    let all_executed = intent.execution_times().is_empty();
    account.intents.destroy_intent<Outcome>(key, all_executed)
}

/// Asserts that the function is called from the module defining the config of the account.
/// Static version: validate witness matches config type (no account needed)
fun assert_is_config_module_static<Config, CW: drop>() {
    let config_type = type_name::with_original_ids<Config>();
    let witness_type = type_name::with_original_ids<CW>();
    assert!(
        config_type.address_string() == witness_type.address_string() &&
        config_type.module_string() == witness_type.module_string(),
        ENotConfigModule,
    );
}

/// Runtime version: validate witness matches stored config type AND exact witness type.
/// SECURITY: Checks full witness type name (not just module/address) to prevent
/// same-module type confusion attacks where a different `drop` type from the config
/// module is used as a fake witness.
public(package) fun assert_is_config_module<Config: store, CW: drop>(
    account: &Account,
    _config_witness: CW,
) {
    // First check the stored type matches requested type
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let requested_type = type_name::with_original_ids<Config>();
    assert!(&requested_type == stored_type, EWrongConfigType);

    // Then validate witness is the EXACT type registered at account creation
    let stored_witness_type = df::borrow<ConfigWitnessTypeKey, TypeName>(
        &account.id,
        ConfigWitnessTypeKey {},
    );
    let witness_type = type_name::with_original_ids<CW>();
    assert!(&witness_type == stored_witness_type, ENotConfigModule);
}

/// Witness-only version: validate witness matches stored witness type exactly.
/// SECURITY: Checks full witness type name (not just module/address) to prevent
/// same-module type confusion attacks.
public(package) fun assert_is_config_module_witness<CW: drop>(
    account: &Account,
    _config_witness: CW,
) {
    // Validate witness is the EXACT type registered at account creation
    let stored_witness_type = df::borrow<ConfigWitnessTypeKey, TypeName>(
        &account.id,
        ConfigWitnessTypeKey {},
    );
    let witness_type = type_name::with_original_ids<CW>();
    assert!(&witness_type == stored_witness_type, ENotConfigModule);
}

/// Cancel an active intent and return its Expired bag for GC draining.
///
/// Security:
/// - `config_witness` gates **authority**: only the Config module may cancel.
/// - Rejects intents that have already completed all executions: those must go
///   through `destroy_empty_intent`, which returns `all_executed = true`. Without
///   this guard, a caller could execute an intent, then cancel it and obtain an
///   `Expired` marked unexecuted — causing cleanup handlers to over-refund.
public fun cancel_intent<Outcome: store + drop, CW: drop>(
    account: &mut Account,
    key: String,
    config_witness: CW,
    ctx: &mut TxContext,
): Expired {
    assert_is_config_module_witness(account, config_witness);
    assert!(
        !account.intents.get<Outcome>(key).execution_times().is_empty(),
        EAlreadyExecuted,
    );
    account.intents.destroy_intent<Outcome>(key, false)
}

/// Helper function to transfer an object to the account.
/// NOTE: This only works for objects going through this function.
/// Anyone can still send objects directly via transfer::public_transfer(obj, account_addr).
/// For spam-resistant storage, use dynamic fields (vault, access_control, etc.) instead.
public fun keep<T: key + store>(account: &Account, obj: T) {
    transfer::public_transfer(obj, account.addr());
}

/// Unpacks and verifies the Auth matches the account.
public fun verify(account: &Account, auth: Auth) {
    let Auth { account_addr } = auth;

    assert!(account.addr() == account_addr, EWrongAccount);
}

/// Returns the account address from Auth.
public fun auth_account_addr(auth: &Auth): address {
    auth.account_addr
}

/// Enforces privileged write authority from active executable context.
/// Invariants:
/// 1. Executable is bound to this account.
/// 2. Caller can construct the current action module's ExecutionProgressWitness.
/// 3. Current action package is authorized by the account deps policy.
public fun assert_execution_authorized<Outcome: store, W: drop>(
    account: &Account,
    registry: &PackageRegistry,
    executable: &Executable<Outcome>,
    action_witness: W,
) {
    // Explicit mismatch check to avoid silently evaluating execution authority against the wrong registry.
    assert!(account.deps.registry_id() == object::id(registry), ERegistryMismatch);
    executable.intent().assert_is_account(account.addr());
    executable::assert_current_action_witness(executable, registry, action_witness);

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    let action_package = intents::action_spec_package_addr(action_spec);
    deps::assert_package_authorized(
        account.deps(),
        registry,
        account.account_deps(),
        action_package,
        object::id(account),
    );
}

/// Enforces package-level policy authorization from an explicit VersionWitness.
/// This is intended for non-executable flows where execution-context authority
/// cannot be used safely (e.g. unshared init or bounded permissionless flows).
public fun assert_package_witness_authorized(
    account: &Account,
    registry: &PackageRegistry,
    version_witness: VersionWitness,
) {
    assert!(account.deps.registry_id() == object::id(registry), ERegistryMismatch);
    // Use check_strict: _with_package_witness functions are always restricted to
    // global registry + whitelist, even under PERMISSIVE mode.
    // PERMISSIVE only loosens the execution flow (proposals/actions), not direct asset access.
    deps::check_strict(
        account.deps(),
        version_witness,
        registry,
        account.account_deps(),
        object::id(account),
    );
}

//**************************************************************************************************//
// Deps-only functions                                                                              //
//**************************************************************************************************//

/// The following functions are used to compose intents in external modules and packages.
///
/// The proper instantiation and execution of an intent is ensured by an intent witness.
/// This is a drop only type defined in the intent module preventing other modules to misuse the intent.
///
/// Additionally, these functions require a version witness from the caller package.
/// It is checked against the account dependency policy to ensure the package being called is authorized.

/// Creates a new intent. Can only be called from a dependency of the account.
public fun create_intent<Outcome: store + drop, IW: drop>(
    account: &Account,
    registry: &PackageRegistry,
    params: Params,
    outcome: Outcome, // resolution settings
    version_witness: VersionWitness, // proof of the package address that creates the intent
    intent_witness: IW, // intent witness
    ctx: &mut TxContext,
): PendingIntent<Outcome> {
    // ensures the package address is authorized by account dependency policy
    assert_package_witness_authorized(account, registry, version_witness);

    params.new_intent(
        outcome,
        account.addr(),
        intent_witness,
        ctx,
    )
}

/// Validates action package authorization at staging time.
fun validate_action_packages_at_staging<Outcome: store>(
    account: &Account,
    registry: &PackageRegistry,
    intent: &Intent<Outcome>,
) {
    let action_specs = intent.action_specs();
    let mut i = 0;
    let len = action_specs.length();
    while (i < len) {
        let action_spec = &action_specs[i];
        let package_addr = intents::action_spec_package_addr(action_spec);
        assert!(
            deps::is_package_authorized(
                account.deps(),
                registry,
                account.account_deps(),
                package_addr,
                object::id(account),
            ),
            EActionPackageNotAuthorized,
        );
        i = i + 1;
    };
}

/// Adds an intent to an unshared account.
/// Security gate is object ownership: caller must hold `&mut Account`.
public fun insert_intent_unshared<Outcome: store + drop, IW: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    intent: PendingIntent<Outcome>,
    _version_witness: VersionWitness,
    intent_witness: IW,
) {
    // Unshared-only API
    assert!(!account.initialized, EAccountAlreadyInitialized);
    let intent_ref = intents::pending_inner(&intent);
    // ensures the right account is passed
    intent_ref.assert_is_account(account.addr());
    // ensures the intent is created by the same package that creates the action
    intent_ref.assert_is_witness(intent_witness);
    validate_action_packages_at_staging(account, registry, intent_ref);
    action_events::emit_intent_action_specs(object::id(account), intent_ref);
    account.intents.add_intent(intents::finish_pending(intent));
}

/// Adds an intent to a shared account.
/// Security gate is config witness: only the active config module can stage.
public fun insert_intent<Config: store, Outcome: store + drop, CW: drop, IW: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    intent: PendingIntent<Outcome>,
    config_witness: CW,
    intent_witness: IW,
) {
    assert_is_config_module<Config, CW>(account, config_witness);
    let intent_ref = intents::pending_inner(&intent);
    // ensures the right account is passed
    intent_ref.assert_is_account(account.addr());
    // ensures the intent is created by the same package that creates the action
    intent_ref.assert_is_witness(intent_witness);
    validate_action_packages_at_staging(account, registry, intent_ref);
    action_events::emit_intent_action_specs(object::id(account), intent_ref);
    account.intents.add_intent(intents::finish_pending(intent));
}

/// Managed data and assets:
/// Data structs and Assets objects attached as dynamic fields to the account object.
/// They are separated to improve objects discoverability on frontends and indexers.
/// Keys must be custom types defined in the same module where the function is implemented.

/// Adds a managed data struct to the account.
public fun add_managed_data<Key: copy + drop + store, Data: store, Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    data: Data,
    executable: &Executable<Outcome>,
    action_witness: W,
) {
    assert_not_reserved_key<Key>();
    assert!(!has_managed_data(account, key), EManagedDataAlreadyExists);
    assert_execution_authorized(account, registry, executable, action_witness);
    df::add(&mut account.id, key, data);
}

/// Adds a managed data struct using package witness authorization.
/// Use this for non-executable flows that still require package policy checks.
public fun add_managed_data_with_package_witness<Key: copy + drop + store, Data: store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    data: Data,
    version_witness: VersionWitness,
) {
    assert_not_reserved_key<Key>();
    assert!(!has_managed_data(account, key), EManagedDataAlreadyExists);
    assert_package_witness_authorized(account, registry, version_witness);
    df::add(&mut account.id, key, data);
}

/// Checks if a managed data struct exists in the account.
public fun has_managed_data<Key: copy + drop + store>(account: &Account, key: Key): bool {
    df::exists_(&account.id, key)
}

/// Borrows a managed data struct from the account using package witness authorization.
public fun borrow_managed_data_with_package_witness<Key: copy + drop + store, Data: store>(
    account: &Account,
    registry: &PackageRegistry,
    key: Key,
    version_witness: VersionWitness,
): &Data {
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    assert_package_witness_authorized(account, registry, version_witness);
    df::borrow(&account.id, key)
}

/// Borrows a managed data struct mutably from the account.
public fun borrow_managed_data_mut<Key: copy + drop + store, Data: store, Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    executable: &Executable<Outcome>,
    action_witness: W,
): &mut Data {
    assert_not_reserved_key<Key>();
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    assert_execution_authorized(account, registry, executable, action_witness);
    df::borrow_mut(&mut account.id, key)
}

/// Borrows a managed data struct mutably using package witness authorization.
public fun borrow_managed_data_mut_with_package_witness<Key: copy + drop + store, Data: store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    version_witness: VersionWitness,
): &mut Data {
    assert_not_reserved_key<Key>();
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    assert_package_witness_authorized(account, registry, version_witness);
    df::borrow_mut(&mut account.id, key)
}

/// Removes a managed data struct from the account.
public fun remove_managed_data<Key: copy + drop + store, A: store, Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    executable: &Executable<Outcome>,
    action_witness: W,
): A {
    assert_not_reserved_key<Key>();
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    assert_execution_authorized(account, registry, executable, action_witness);
    df::remove(&mut account.id, key)
}

/// Removes a managed data struct using package witness authorization.
public fun remove_managed_data_with_package_witness<Key: copy + drop + store, A: store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    version_witness: VersionWitness,
): A {
    assert_not_reserved_key<Key>();
    assert!(has_managed_data(account, key), EManagedDataDoesntExist);
    assert_package_witness_authorized(account, registry, version_witness);
    df::remove(&mut account.id, key)
}

/// Adds a managed object to the account.
public fun add_managed_asset<Key: copy + drop + store, Asset: key + store, Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    asset: Asset,
    executable: &Executable<Outcome>,
    action_witness: W,
) {
    assert_not_reserved_key<Key>();
    assert!(!has_managed_asset(account, key), EManagedAssetAlreadyExists);
    assert_execution_authorized(account, registry, executable, action_witness);
    dof::add(&mut account.id, key, asset);
}

/// Adds a managed object using package witness authorization.
public fun add_managed_asset_with_package_witness<Key: copy + drop + store, Asset: key + store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    asset: Asset,
    version_witness: VersionWitness,
) {
    assert_not_reserved_key<Key>();
    assert!(!has_managed_asset(account, key), EManagedAssetAlreadyExists);
    assert_package_witness_authorized(account, registry, version_witness);
    dof::add(&mut account.id, key, asset);
}

/// Checks if a managed object exists in the account.
public fun has_managed_asset<Key: copy + drop + store>(account: &Account, key: Key): bool {
    dof::exists_(&account.id, key)
}

/// Borrows a managed object from the account using package witness authorization.
public fun borrow_managed_asset_with_package_witness<Key: copy + drop + store, Asset: key + store>(
    account: &Account,
    registry: &PackageRegistry,
    key: Key,
    version_witness: VersionWitness,
): &Asset {
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    assert_package_witness_authorized(account, registry, version_witness);
    dof::borrow(&account.id, key)
}

/// Borrows a managed object mutably from the account.
public fun borrow_managed_asset_mut<Key: copy + drop + store, Asset: key + store, Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    executable: &Executable<Outcome>,
    action_witness: W,
): &mut Asset {
    assert_not_reserved_key<Key>();
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    assert_execution_authorized(account, registry, executable, action_witness);
    dof::borrow_mut(&mut account.id, key)
}

/// Borrows a managed object mutably using package witness authorization.
public fun borrow_managed_asset_mut_with_package_witness<Key: copy + drop + store, Asset: key + store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    version_witness: VersionWitness,
): &mut Asset {
    assert_not_reserved_key<Key>();
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    assert_package_witness_authorized(account, registry, version_witness);
    dof::borrow_mut(&mut account.id, key)
}

/// Removes a managed object from the account.
public fun remove_managed_asset<Key: copy + drop + store, Asset: key + store, Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    executable: &Executable<Outcome>,
    action_witness: W,
): Asset {
    assert_not_reserved_key<Key>();
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    assert_execution_authorized(account, registry, executable, action_witness);
    dof::remove(&mut account.id, key)
}

/// Removes a managed object using package witness authorization.
public fun remove_managed_asset_with_package_witness<Key: copy + drop + store, Asset: key + store>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: Key,
    version_witness: VersionWitness,
): Asset {
    assert_not_reserved_key<Key>();
    assert!(has_managed_asset(account, key), EManagedAssetDoesntExist);
    assert_package_witness_authorized(account, registry, version_witness);
    dof::remove(&mut account.id, key)
}

//**************************************************************************************************//
// Config-only functions                                                                            //
//**************************************************************************************************//

/// The following functions are used to define account and intent behavior for a specific account type/config.
///
/// They must be implemented in the module that defines the config of the account, which must be a dependency of the account.
/// We provide higher level macros to facilitate the implementation of these functions.

/// Creates a new account with default dependencies. Can only be called from the config module.
/// This function is for FREE account creation only. If a fee is configured, use new_with_payment instead.
///
/// Security: Account creation is gated by the config_witness parameter. Only the module that
/// defines Config can create instances of CW, ensuring only authorized code can create accounts.
public fun new<Config: store, CW: drop>(
    config: Config,
    metadata: Metadata,
    mut deps: Deps,
    config_witness: CW,
    ctx: &mut TxContext,
): Account {
    // Validate witness matches config module at compile time
    assert_is_config_module_static<Config, CW>();

    let uid = object::new(ctx);
    let account_id = object::uid_to_inner(&uid);
    deps::bind_account_id(&mut deps, account_id);

    let mut account = Account {
        id: uid,
        metadata,
        deps,
        intents: intents::empty(ctx),
        initialized: false,
    };

    // Initialize per-account deps table as dynamic field
    let account_deps_table = deps::new_account_deps_table(ctx);
    df::add(&mut account.id, deps::account_deps_key(), account_deps_table);
    // Initialize dep names reverse index (name -> address) for uniqueness enforcement
    df::add(&mut account.id, deps::dep_names_key(), deps::new_dep_names_map());

    // Store config, its type, and the exact witness type as dynamic fields
    df::add(&mut account.id, ConfigKey {}, config);
    df::add(&mut account.id, ConfigTypeKey {}, type_name::with_original_ids<Config>());
    df::add(&mut account.id, ConfigWitnessTypeKey {}, type_name::with_original_ids<CW>());

    account
}

/// Returns an Auth object that can be used to call gated functions. Can only be called from the config module.
public fun new_auth<Config: store, CW: drop>(
    account: &Account,
    config_witness: CW,
): Auth {
    assert_is_config_module<Config, CW>(account, config_witness);

    Auth { account_addr: account.addr() }
}

/// Returns a tuple of the outcome that must be validated and the executable. Can only be called from the config module.
///
/// Authorization levels for action packages at executable creation and execution:
/// - Level 0 (GLOBAL_ONLY): Action packages must be in the global registry
/// - Level 1 (WHITELIST): Action packages must be in global registry OR account whitelist
/// - Level 2 (PERMISSIVE): Any action package is allowed
public fun create_executable<Config: store, Outcome: store + copy, CW: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    key: String,
    clock: &Clock,
    config_witness: CW,
    ctx: &mut TxContext, // used to create the Executable UID
): (Outcome, Executable<Outcome>) {
    assert_is_config_module<Config, CW>(account, config_witness);

    let mut intent = account.intents.remove_intent<Outcome>(key);
    let time = intent.pop_front_execution_time();
    assert!(clock.timestamp_ms() >= time, ECantBeExecutedYet);
    // Legacy zero-expiry intents are intentionally unsupported post-upgrade.
    assert!(clock.timestamp_ms() < intent.expiration_time(), EIntentExpired);

    // Re-validate action packages against current local deps and global registry.
    let action_specs = intent.action_specs();
    let mut i = 0;
    let len = action_specs.length();
    while (i < len) {
        let action_spec = &action_specs[i];
        let package_addr = intents::action_spec_package_addr(action_spec);
        assert!(
            deps::is_package_authorized(
                account.deps(),
                registry,
                account.account_deps(),
                package_addr,
                object::id(account),
            ),
            EActionPackageNotAuthorized,
        );
        i = i + 1;
    };

    (
        *intent.outcome(),
        executable::new(intent, ctx),
    )
}

/// Returns a mutable reference to the intents of the account.
/// Only callable by the config module (enforced by assert_is_config_module).
public fun intents_mut<Config: store, CW: drop>(
    account: &mut Account,
    config_witness: CW,
): &mut Intents {
    assert_is_config_module<Config, CW>(account, config_witness);

    &mut account.intents
}

/// Returns a mutable reference to the config of the account. Can only be called from the config module.
/// SECURITY: Restricted to uninitialized (unshared) accounts only.
/// For shared accounts, use config_mut_authorized which requires package-level deps policy auth.
public fun config_mut<Config: store, CW: drop>(
    account: &mut Account,
    config_witness: CW,
): &mut Config {
    assert!(!account.initialized, EAccountAlreadyInitialized);
    assert_is_config_module<Config, CW>(account, config_witness);

    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
}

fun assert_stored_config_type<Config: store>(account: &Account): TypeName {
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let requested_type = type_name::with_original_ids<Config>();
    assert!(&requested_type == stored_type, EWrongConfigType);
    requested_type
}

fun type_name_package_addr(type_name_ref: &TypeName): address {
    address::from_bytes(hex::decode(type_name::address_string(type_name_ref).into_bytes()))
}

/// Returns a mutable reference to the config of the account.
/// Requires package-level authorization through deps policy.
/// Use this for all config mutations on shared (initialized) accounts.
///
/// SECURITY: The caller's VersionWitness must come from the package that defines the
/// stored config type. Globally registered action packages may not borrow config directly.
public fun config_mut_authorized<Config: store>(
    account: &mut Account,
    registry: &PackageRegistry,
    version_witness: VersionWitness,
): &mut Config {
    assert_package_witness_authorized(account, registry, copy version_witness);
    let config_type = assert_stored_config_type<Config>(account);
    assert!(
        version_witness.package_addr() == type_name_package_addr(&config_type),
        EActionPackageNotAuthorized,
    );
    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
}

/// Returns a mutable reference to the config of the account bound to active executable context.
/// This is the preferred path for shared-account config mutation during action execution.
///
/// SECURITY: Requires both an authorized executable action and the exact config witness
/// registered at account creation. External action packages should call narrow wrappers
/// exposed by the config module instead of borrowing the config directly.
public fun config_mut_from_execution<Config: store, Outcome: store, W: drop, CW: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    executable: &Executable<Outcome>,
    action_witness: W,
    config_witness: CW,
): &mut Config {
    assert_is_config_module<Config, CW>(account, config_witness);
    assert_execution_authorized(account, registry, executable, action_witness);
    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    let action_package = intents::action_spec_package_addr(action_spec);
    assert!(
        package_registry::contains_package_addr(registry, action_package),
        EActionPackageNotAuthorized,
    );
    df::borrow_mut<ConfigKey, Config>(&mut account.id, ConfigKey {})
}

/// Migrate account config from one type to another.
///
/// This is a DANGEROUS operation that changes the config type stored in the Account.
/// Should only be called via governance after thorough validation.
///
/// # Type Parameters:
/// * `OldConfig` - Current config type (must match what's stored)
/// * `NewConfig` - New config type to migrate to
///
/// # Arguments:
/// * `account` - The account to migrate
/// * `new_config` - The new config data
/// * `registry` - Package registry that must match the account deps registry
///
/// # Returns:
/// The old config (for validation/destruction)
///
/// # Safety:
/// - Checks registry binding consistency
/// - Validates OldConfig matches stored type
/// - Swaps config dynamic field atomically
/// - Updates type tracking
/// - Returns old config for validation before destruction
///
/// # Aborts:
/// - If OldConfig doesn't match stored config type
/// - If registry does not match account deps registry
public fun migrate_config<OldConfig: store, OldCW: drop, NewConfig: store, NewCW: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    old_config_witness: OldCW,
    new_config: NewConfig,
): OldConfig {
    assert!(account.deps.registry_id() == object::id(registry), ERegistryMismatch);
    // Validate caller owns the old config's witness before allowing migration
    assert_is_config_module_witness(account, old_config_witness);
    assert_is_config_module_static<NewConfig, NewCW>();

    // Validate that OldConfig matches what's currently stored
    let stored_type = df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {});
    let old_type = type_name::with_original_ids<OldConfig>();
    assert!(&old_type == stored_type, EWrongConfigType);

    // Remove old config from dynamic field
    let old_config: OldConfig = df::remove(&mut account.id, ConfigKey {});

    // Add new config to dynamic field
    df::add(&mut account.id, ConfigKey {}, new_config);

    // Update type tracking
    let _old_type_removed: TypeName = df::remove(&mut account.id, ConfigTypeKey {});
    df::add(&mut account.id, ConfigTypeKey {}, type_name::with_original_ids<NewConfig>());
    let _old_witness_type: TypeName = df::remove(&mut account.id, ConfigWitnessTypeKey {});
    df::add(&mut account.id, ConfigWitnessTypeKey {}, type_name::with_original_ids<NewCW>());

    // Return old config for caller to validate/destroy
    old_config
}

//**************************************************************************************************//
// View functions                                                                                   //
//**************************************************************************************************//

/// Returns the address of the account.
public fun addr(account: &Account): address {
    account.id.uid_to_inner().id_to_address()
}

/// Returns the metadata of the account.
public fun metadata(account: &Account): &Metadata {
    &account.metadata
}

/// Returns the dependencies of the account.
public fun deps(account: &Account): &Deps {
    &account.deps
}

/// Returns whether the account has been initialized (shared).
/// SECURITY: Used by _unshared functions to prevent auth bypass attacks.
public fun is_initialized(account: &Account): bool {
    account.initialized
}

/// Asserts that the account has NOT been initialized (shared).
/// SECURITY: Call this at the start of all _unshared functions to prevent
/// calling them on shared accounts, which would bypass Auth checks.
public fun assert_not_initialized(account: &Account) {
    assert!(!account.initialized, EAccountAlreadyInitialized);
}

/// Returns the per-account deps table (for package authorization checks)
public fun account_deps(account: &Account): &Table<address, DepInfo> {
    df::borrow(&account.id, deps::account_deps_key())
}

/// Returns mutable reference to per-account deps table
public(package) fun account_deps_mut(account: &mut Account): &mut Table<address, DepInfo> {
    df::borrow_mut(&mut account.id, deps::account_deps_key())
}

public(package) fun has_dep_names(account: &Account): bool {
    df::exists_(&account.id, deps::dep_names_key())
}

/// Returns mutable reference to dep names reverse index.
/// Fresh deployments require it to exist for every account. Missing state fails
/// closed rather than trying to reconstruct it.
public(package) fun dep_names_mut(account: &mut Account): &mut VecMap<String, address> {
    assert!(df::exists_(&account.id, deps::dep_names_key()), EDepNamesMissing);
    df::borrow_mut(&mut account.id, deps::dep_names_key())
}

/// Returns the intents of the account.
public fun intents(account: &Account): &Intents {
    &account.intents
}

/// Returns the config of the account.
public fun config<Config: store>(account: &Account): &Config {
    df::borrow<ConfigKey, Config>(&account.id, ConfigKey {})
}

/// Returns the type name of the config stored in the account.
/// Useful for migration validation and runtime type checking.
public fun config_type(account: &Account): TypeName {
    *df::borrow<ConfigTypeKey, TypeName>(&account.id, ConfigTypeKey {})
}

//**************************************************************************************************//
// Package functions                                                                                //
//**************************************************************************************************//

/// Returns a mutable reference to the metadata of the account.
public(package) fun metadata_mut<Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    executable: &Executable<Outcome>,
    action_witness: W,
): &mut Metadata {
    assert_execution_authorized(account, registry, executable, action_witness);
    &mut account.metadata
}

/// Returns a mutable reference to the deps of the account.
/// Used by config actions to modify per-account package dependencies.
public(package) fun deps_mut<Outcome: store, W: drop>(
    account: &mut Account,
    registry: &PackageRegistry,
    executable: &Executable<Outcome>,
    action_witness: W,
): &mut Deps {
    assert_execution_authorized(account, registry, executable, action_witness);
    &mut account.deps
}

/// Receives an object owned by the account, only used in owned action lib module.
/// NOTE: This is for WITHDRAWALS - receiving an object FROM the account to return it.
public(package) fun receive<T: key + store>(account: &mut Account, receiving: Receiving<T>): T {
    transfer::public_receive(&mut account.id, receiving)
}

//**************************************************************************************************//
// Tests                                                                                            //
//**************************************************************************************************//

// === Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ACCOUNT {}, ctx);
}

#[test_only]
public struct Witness has drop {}

#[test_only]
public fun not_config_witness(): Witness {
    Witness {}
}

// === Unit Tests ===

#[test_only]
use account_protocol::version;
#[test_only]
use sui::test_utils::{assert_eq, destroy};
#[test_only]
public struct TestConfig has copy, drop, store {}
#[test_only]
public struct TestWitness() has drop;

#[test_only]
public struct TestWitness2() has drop;

#[test_only]
public struct WrongWitness() has drop;
#[test_only]
public struct MigratedConfig has copy, drop, store {
    value: u64,
}

#[test_only]
public struct MigratedWitness() has drop;
#[test_only]
public struct TestKey has copy, drop, store {}
#[test_only]
public struct TestData has copy, drop, store {
    value: u64,
}
#[test_only]
public struct TestAsset has key, store {
    id: UID,
}

#[test]
fun test_addr() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let account_addr = addr(&account);

    assert_eq(account_addr, object::id(&account).to_address());
    destroy(account);
    destroy(registry);
}

#[test]
fun test_verify_auth() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let auth = Auth { account_addr: account.addr() };

    // Should not abort
    verify(&account, auth);
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EWrongAccount)]
fun test_verify_auth_wrong_account() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let auth = Auth { account_addr: @0xBAD };

    verify(&account, auth);
    destroy(account);
    destroy(registry);
}

#[test]
fun test_managed_data_flow() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};
    let data = TestData { value: 42 };

    // Test add
    add_managed_data_with_package_witness(&mut account, &registry, key, data, version::current());
    assert!(has_managed_data(&account, key));

    // Test borrow
    let borrowed_data = borrow_managed_data_with_package_witness(
        &account,
        &registry,
        key,
        version::current(),
    );
    assert_eq(*borrowed_data, data);

    // Test borrow_mut
    let borrowed_mut_data = borrow_managed_data_mut_with_package_witness(
        &mut account,
        &registry,
        key,
        version::current(),
    );
    assert_eq(*borrowed_mut_data, data);

    // Test remove
    let removed_data = remove_managed_data_with_package_witness(&mut account, &registry, key, version::current());
    assert_eq(removed_data, data);
    assert!(!has_managed_data(&account, key));
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedDataAlreadyExists)]
fun test_add_managed_data_already_exists() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};
    let data1 = TestData { value: 42 };
    let data2 = TestData { value: 100 };

    add_managed_data_with_package_witness(&mut account, &registry, key, data1, version::current());
    add_managed_data_with_package_witness(&mut account, &registry, key, data2, version::current());
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedDataDoesntExist)]
fun test_borrow_managed_data_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_data_with_package_witness<TestKey, TestData>(
        &account,
        &registry,
        key,
        version::current(),
    );
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedDataDoesntExist)]
fun test_borrow_managed_data_mut_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_data_mut_with_package_witness<TestKey, TestData>(&mut account, &registry, key, version::current());
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedDataDoesntExist)]
fun test_remove_managed_data_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    remove_managed_data_with_package_witness<TestKey, TestData>(&mut account, &registry, key, version::current());
    destroy(account);
    destroy(registry);
}

#[test]
fun test_managed_asset_flow() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};
    let asset = TestAsset { id: object::new(ctx) };
    let asset_id = object::id(&asset);

    // Test add
    add_managed_asset_with_package_witness(&mut account, &registry, key, asset, version::current());
    assert!(has_managed_asset(&account, key), 0);

    // Test borrow
    let borrowed_asset = borrow_managed_asset_with_package_witness<TestKey, TestAsset>(
        &account,
        &registry,
        key,
        version::current(),
    );
    let borrowed_asset_id = object::id(borrowed_asset);
    assert_eq(borrowed_asset_id, asset_id);

    // Test remove
    let removed_asset = remove_managed_asset_with_package_witness<TestKey, TestAsset>(
        &mut account,
        &registry,
        key,
        version::current(),
    );
    assert_eq(object::id(&removed_asset), asset_id);
    assert!(!has_managed_asset(&account, key));
    destroy(account);
    destroy(removed_asset);
    destroy(registry);
}

#[test]
fun test_has_managed_data_false() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    assert!(!has_managed_data(&account, key));
    destroy(account);
    destroy(registry);
}

#[test]
fun test_has_managed_asset_false() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    assert!(!has_managed_asset(&account, key));
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedAssetAlreadyExists)]
fun test_add_managed_asset_already_exists() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};
    let asset1 = TestAsset { id: object::new(ctx) };
    let asset2 = TestAsset { id: object::new(ctx) };

    add_managed_asset_with_package_witness(&mut account, &registry, key, asset1, version::current());
    add_managed_asset_with_package_witness(&mut account, &registry, key, asset2, version::current());
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedAssetDoesntExist)]
fun test_borrow_managed_asset_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_asset_with_package_witness<TestKey, TestAsset>(
        &account,
        &registry,
        key,
        version::current(),
    );
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedAssetDoesntExist)]
fun test_borrow_managed_asset_mut_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    borrow_managed_asset_mut_with_package_witness<TestKey, TestAsset>(&mut account, &registry, key, version::current());
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EManagedAssetDoesntExist)]
fun test_remove_managed_asset_doesnt_exist() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let key = TestKey {};

    let removed_asset = remove_managed_asset_with_package_witness<TestKey, TestAsset>(
        &mut account,
        &registry,
        key,
        version::current(),
    );
    destroy(removed_asset);
    destroy(account);
    destroy(registry);
}

#[test]
fun test_new_auth() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let auth = new_auth<TestConfig, TestWitness>(&account, TestWitness());

    assert_eq(auth.account_addr, account.addr());
    destroy(account);
    destroy(auth);
    destroy(registry);
}

#[test]
fun test_metadata_access() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);

    // Should not abort - just testing access
    assert_eq(metadata(&account).size(), 0);
    destroy(account);
    destroy(registry);
}

#[test]
fun test_config_access() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);

    // Should not abort - just testing access
    config<TestConfig>(&account);
    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = EActionPackageNotAuthorized)]
fun test_config_mut_authorized_rejects_non_config_package_witness() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    package_registry::add_for_testing(
        &mut registry,
        b"OtherPackage".to_string(),
        @0xBEEF,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));
    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);

    let other_package_witness = version_witness::new_for_testing(@0xBEEF);
    config_mut_authorized<TestConfig>(&mut account, &registry, other_package_witness);

    destroy(account);
    destroy(registry);
}

#[test]
fun test_assert_is_config_module_correct_witness() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);

    // Should not abort
    assert_is_config_module<TestConfig, TestWitness>(&account, TestWitness());
    destroy(account);
    destroy(registry);
}

#[test]
fun test_migrate_config_updates_witness_type_key() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let old_config = migrate_config<TestConfig, TestWitness, MigratedConfig, MigratedWitness>(
        &mut account,
        &registry,
        TestWitness(),
        MigratedConfig { value: 7 },
    );
    let _ = old_config;

    assert_is_config_module<MigratedConfig, MigratedWitness>(&account, MigratedWitness());
    assert_eq(config<MigratedConfig>(&account).value, 7);

    destroy(account);
    destroy(registry);
}

#[test, expected_failure(abort_code = ENotConfigModule)]
fun test_migrate_config_rejects_old_witness_type() {
    let ctx = &mut tx_context::dummy();
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));

    let mut account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    let old_config = migrate_config<TestConfig, TestWitness, MigratedConfig, MigratedWitness>(
        &mut account,
        &registry,
        TestWitness(),
        MigratedConfig { value: 9 },
    );
    let _ = old_config;

    // Old witness must no longer authorize config-module actions after migration.
    assert_is_config_module_witness<TestWitness>(&account, TestWitness());
    destroy(account);
    destroy(registry);
}

// === Test Helper Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Account {
    let mut registry = package_registry::new_for_testing(ctx);
    package_registry::add_for_testing(
        &mut registry,
        b"AccountProtocol".to_string(),
        @account_protocol,
        1,
    );
    let deps = deps::new_for_testing(&registry, object::id_from_address(@0x0));
    let account = new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx);
    destroy(registry);
    account
}

#[test_only]
public fun new_for_testing_with_registry(registry: &PackageRegistry, ctx: &mut TxContext): Account {
    let deps = deps::new_for_testing(registry, object::id_from_address(@0x0));
    new(TestConfig {}, metadata::empty(), deps, TestWitness(), ctx)
}

#[test_only]
public fun remove_dep_names_key_for_testing(account: &mut Account) {
    if (df::exists_(&account.id, deps::dep_names_key())) {
        let _: VecMap<String, address> = df::remove(&mut account.id, deps::dep_names_key());
    };
}

#[test_only]
public fun destroy_for_testing<Config: store>(account: Account) {
    destroy(account);
}

// === Share Functions ===

/// Share an account.
/// Used during DAO/account initialization after setup is complete.
/// SECURITY: Sets initialized=true before sharing to permanently disable _unshared APIs.
/// If you need unshared init actions, perform them before calling share_account.
public fun share_account(mut account: Account) {
    account.initialized = true;
    transfer::share_object(account);
}

/// Mark account as initialized after init actions complete on shared account.
/// SECURITY: Call this after all init actions to lock down _unshared functions.
/// Idempotent - safe to call multiple times.
///
/// Use case: If an account was shared via `transfer::share_object` without going through
/// `account::share_account`, this lets the config module lock down _unshared functions.
///
/// SECURITY: Requires the config module witness of the currently installed config.
public fun mark_initialized<CW: drop>(
    account: &mut Account,
    config_witness: CW,
) {
    assert_is_config_module_witness(account, config_witness);
    account.initialized = true;
}
