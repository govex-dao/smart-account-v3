// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// Package upgrade management for Account-controlled UpgradeCaps.
///
/// Pattern:
/// - Lock UpgradeCap into Account storage via `LockUpgradeCap` action
/// - Stage `PackageUpgrade` + `PackageCommit` actions in one intent
/// - Execute `do_init_upgrade` to get UpgradeTicket
/// - Consume ticket in PTB upgrade command
/// - Execute `do_init_commit` with UpgradeReceipt
///
/// Policy can only be made more restrictive via `do_init_restrict`.
module account_actions::package_upgrade;

public struct ExecutionProgressWitness has drop {}

use account_actions::actions_version as version;
use account_protocol::account::{Self, Account};
#[test_only]
use account_protocol::account::Auth;
use account_protocol::bcs_validation;
use account_protocol::executable::{Self, Executable};
use account_protocol::executable_resources;
use account_protocol::intents;
use account_protocol::package_registry::PackageRegistry;
use std::string::String;
use sui::bcs;
use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID};
use sui::package::{Self, UpgradeCap, UpgradeReceipt, UpgradeTicket};
use sui::vec_map::{Self, VecMap};

// === Errors ===

const ELockAlreadyExists: u64 = 0;
const EUpgradeTooEarly: u64 = 1;
const EPackageDoesntExist: u64 = 2;
const EUnsupportedActionVersion: u64 = 3;
const EReceiptPackageMismatch: u64 = 4;
const EInvalidPolicy: u64 = 5;
const EPolicyShouldRestrict: u64 = 6;
const EEmptyPackageName: u64 = 7;
const EPackageNameAlreadyUsed: u64 = 8;
const EUpgradeCapIdMismatch: u64 = 9;
const ECapNotInPendingUpgradeState: u64 = 10;
const EInvalidPackageAddress: u64 = 11;

// === Events ===

/// Emitted when an UpgradeCap is locked into the account.
public struct UpgradeCapLocked has copy, drop {
    account_id: ID,
    package_name: String,
    package_addr: address,
    delay_ms: u64,
    policy: u8,
}

/// Emitted when an upgrade is authorized and ticket returned.
public struct UpgradeAuthorized has copy, drop {
    account_id: ID,
    package_name: String,
    package_addr: address,
    policy: u8,
}

/// Emitted when an upgrade is committed.
public struct UpgradeCommitted has copy, drop {
    account_id: ID,
    package_name: String,
    old_package_addr: address,
    new_package_addr: address,
}

/// Emitted when upgrade policy is restricted.
public struct UpgradePolicyRestricted has copy, drop {
    account_id: ID,
    package_name: String,
    old_policy: u8,
    new_policy: u8,
    made_immutable: bool,
}

/// Emitted when an UpgradeCap is unlocked into executable_resources.
public struct UpgradeCapUnlocked has copy, drop {
    account_id: ID,
    package_name: String,
    package_addr: address,
    resource_name: String,
}

// === Action Type Markers ===

/// Authorize a package upgrade.
public struct PackageUpgrade has drop {}
/// Commit an already authorized package upgrade.
public struct PackageCommit has drop {}
/// Restrict upgrade policy for a package.
public struct PackageRestrict has drop {}
/// Lock an UpgradeCap into the account via governance.
public struct LockUpgradeCap has drop {}
/// Unlock an UpgradeCap from the account into executable_resources.
public struct UnlockUpgradeCap has drop {}

// === Marker Constructors ===

public(package) fun package_upgrade_marker(): PackageUpgrade { PackageUpgrade {} }

public(package) fun package_commit_marker(): PackageCommit { PackageCommit {} }

public(package) fun package_restrict_marker(): PackageRestrict { PackageRestrict {} }

public(package) fun lock_upgrade_cap_marker(): LockUpgradeCap { LockUpgradeCap {} }

public(package) fun unlock_upgrade_cap_marker(): UnlockUpgradeCap { UnlockUpgradeCap {} }

// === Structs ===

/// Dynamic object field key for a locked UpgradeCap.
public struct UpgradeCapKey(String) has copy, drop, store;
/// Dynamic field key for per-package upgrade rules.
public struct UpgradeRulesKey(String) has copy, drop, store;
/// Dynamic field key for package-name -> package-address index.
public struct UpgradeIndexKey() has copy, drop, store;

/// Per-package upgrade rules.
public struct UpgradeRules has store {
    // Minimum delay between proposal creation and upgrade authorization.
    delay_ms: u64,
}

/// Tracks latest package address by package name.
public struct UpgradeIndex has store {
    packages_info: VecMap<String, address>,
}

// === Public Constants ===

/// Special policy value that destroys the cap and makes package immutable.
public fun immutable_policy(): u8 { 255 }

/// Returns true if policy is one of the allowed restrict targets.
public fun is_valid_restrict_policy(policy: u8): bool {
    policy == package::additive_policy() ||
    policy == package::dep_only_policy() ||
    policy == immutable_policy()
}

// === Public Functions ===

/// Lock an UpgradeCap in the account with a minimum delay for upgrades.
/// NOTE: Only used in tests. Production code uses `do_init_lock_upgrade_cap`.
#[test_only]
public fun lock_cap(
    auth: Auth,
    account: &mut Account,
    registry: &PackageRegistry,
    cap: UpgradeCap,
    name: String,
    delay_ms: u64,
) {
    account.verify(auth);
    assert!(name.length() > 0, EEmptyPackageName);
    assert!(!has_cap(account, name), ELockAlreadyExists);

    let package_addr = cap.package().to_address();
    assert!(package_addr != @0x0, EInvalidPackageAddress);
    let policy = cap.policy();

    if (!account.has_managed_data(UpgradeIndexKey())) {
        account.add_managed_data_with_package_witness(
            registry,
            UpgradeIndexKey(),
            UpgradeIndex { packages_info: vec_map::empty() },
            version::current(),
        );
    };

    let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut_with_package_witness(
        registry,
        UpgradeIndexKey(),
        version::current(),
    );
    assert!(!index_mut.packages_info.contains(&name), EPackageNameAlreadyUsed);
    index_mut.packages_info.insert(name, package_addr);

    account.add_managed_asset_with_package_witness(
        registry,
        UpgradeCapKey(name),
        cap,
        version::current(),
    );
    account.add_managed_data_with_package_witness(
        registry,
        UpgradeRulesKey(name),
        UpgradeRules { delay_ms },
        version::current(),
    );

    event::emit(UpgradeCapLocked {
        account_id: object::id(account),
        package_name: name,
        package_addr,
        delay_ms,
        policy,
    });
}

/// Returns true if the account has a locked UpgradeCap for this package name.
public fun has_cap(account: &Account, name: String): bool {
    account.has_managed_asset(UpgradeCapKey(name))
}

/// Returns current package address for a locked cap.
public fun get_cap_package(
    account: &Account,
    registry: &PackageRegistry,
    name: String,
): address {
    let cap: &UpgradeCap = account.borrow_managed_asset_with_package_witness(
        registry,
        UpgradeCapKey(name),
        version::current(),
    );
    cap.package().to_address()
}

/// Returns current version number from the locked cap.
public fun get_cap_version(
    account: &Account,
    registry: &PackageRegistry,
    name: String,
): u64 {
    let cap: &UpgradeCap = account.borrow_managed_asset_with_package_witness(
        registry,
        UpgradeCapKey(name),
        version::current(),
    );
    cap.version()
}

/// Returns current upgrade policy from the locked cap.
public fun get_cap_policy(
    account: &Account,
    registry: &PackageRegistry,
    name: String,
): u8 {
    let cap: &UpgradeCap = account.borrow_managed_asset_with_package_witness(
        registry,
        UpgradeCapKey(name),
        version::current(),
    );
    cap.policy()
}

/// Returns minimum delay configured for package upgrades.
public fun get_time_delay(
    account: &Account,
    registry: &PackageRegistry,
    name: String,
): u64 {
    let rules: &UpgradeRules = account.borrow_managed_data_with_package_witness(
        registry,
        UpgradeRulesKey(name),
        version::current(),
    );
    rules.delay_ms
}

/// Returns package-name -> package-address index.
public fun get_packages_info(
    account: &Account,
    registry: &PackageRegistry,
): &VecMap<String, address> {
    let index: &UpgradeIndex = account.borrow_managed_data_with_package_witness(
        registry,
        UpgradeIndexKey(),
        version::current(),
    );
    &index.packages_info
}

/// Returns true if this package address is tracked by the account index.
public fun is_package_managed(
    account: &Account,
    registry: &PackageRegistry,
    package_addr: address,
): bool {
    if (!account.has_managed_data(UpgradeIndexKey())) return false;

    let index: &UpgradeIndex = account.borrow_managed_data_with_package_witness(
        registry,
        UpgradeIndexKey(),
        version::current(),
    );
    let mut i = 0;
    while (i < index.packages_info.length()) {
        let (_, value) = index.packages_info.get_entry_by_idx(i);
        if (value == package_addr) return true;
        i = i + 1;
    };
    false
}

/// Returns tracked package address by package name.
public fun get_package_addr(
    account: &Account,
    registry: &PackageRegistry,
    package_name: String,
): address {
    let index: &UpgradeIndex = account.borrow_managed_data_with_package_witness(
        registry,
        UpgradeIndexKey(),
        version::current(),
    );
    *index.packages_info.get(&package_name)
}

/// Returns tracked package name by package address.
public fun get_package_name(
    account: &Account,
    registry: &PackageRegistry,
    package_addr: address,
): String {
    let index: &UpgradeIndex = account.borrow_managed_data_with_package_witness(
        registry,
        UpgradeIndexKey(),
        version::current(),
    );
    let mut i = 0;
    while (i < index.packages_info.length()) {
        let (name, addr) = index.packages_info.get_entry_by_idx(i);
        if (addr == package_addr) return *name;
        i = i + 1;
    };
    abort EPackageDoesntExist
}

// === Layer 3: Init Action Execution ===

/// Execute `PackageUpgrade` action and return `UpgradeTicket`.
public fun do_init_upgrade<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    clock: &Clock,
    _intent_witness: IW,
): UpgradeTicket {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<PackageUpgrade>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let digest = bcs::peel_vec_u8(&mut reader);
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name.length() > 0, EEmptyPackageName);

    let delay_ms = {
        let rules: &mut UpgradeRules = account.borrow_managed_data_mut(
            registry,
            UpgradeRulesKey(name),
            executable,
            ExecutionProgressWitness {},
        );
        rules.delay_ms
    };

    assert!(
        clock.timestamp_ms() >= executable.intent().creation_time() + delay_ms,
        EUpgradeTooEarly,
    );

    let account_id = object::id(account);
    let (policy, package_addr, ticket) = {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(
            registry,
            UpgradeCapKey(name),
            executable,
            ExecutionProgressWitness {},
        );
        assert!(object::id(cap_mut) == expected_cap_id, EUpgradeCapIdMismatch);
        let policy = cap_mut.policy();
        let package_addr = cap_mut.package().to_address();
        let ticket = cap_mut.authorize_upgrade(policy, digest);
        (policy, package_addr, ticket)
    };

    event::emit(UpgradeAuthorized {
        account_id,
        package_name: name,
        package_addr,
        policy,
    });

    executable::increment_action_idx<_, PackageUpgrade, _>(executable, registry, ExecutionProgressWitness {});
    ticket
}

/// Execute `PackageCommit` action with an `UpgradeReceipt`.
public fun do_init_commit<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    receipt: UpgradeReceipt,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<PackageCommit>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name.length() > 0, EEmptyPackageName);

    // Commit the upgrade and get the new package address.
    // NOTE: We do NOT read old_package_addr from the cap here because
    // authorize_upgrade (called in do_init_upgrade) zeros cap.package.
    // Instead we read it from the UpgradeIndex which has the true address.
    let new_package_addr = {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(
            registry,
            UpgradeCapKey(name),
            executable,
            ExecutionProgressWitness {},
        );
        assert!(object::id(cap_mut) == expected_cap_id, EUpgradeCapIdMismatch);
        assert!(receipt.cap() == object::id(cap_mut), EReceiptPackageMismatch);

        // Defense-in-depth: verify cap is in pending-upgrade state.
        // authorize_upgrade (called in do_init_upgrade) zeros cap.package,
        // so a non-zero value means no authorize_upgrade was called on this
        // cap in this PTB — reject to prevent externally-sourced receipts.
        assert!(cap_mut.package().to_address() == @0x0, ECapNotInPendingUpgradeState);

        cap_mut.commit_upgrade(receipt);
        cap_mut.package().to_address()
    };

    let old_package_addr = {
        let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(
            registry,
            UpgradeIndexKey(),
            executable,
            ExecutionProgressWitness {},
        );
        let old = *index_mut.packages_info.get(&name);
        *index_mut.packages_info.get_mut(&name) = new_package_addr;
        old
    };

    event::emit(UpgradeCommitted {
        account_id: object::id(account),
        package_name: name,
        old_package_addr,
        new_package_addr,
    });

    executable::increment_action_idx<_, PackageCommit, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute `PackageRestrict` action and tighten cap policy.
public fun do_init_restrict<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<PackageRestrict>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let policy = bcs::peel_u8(&mut reader);
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name.length() > 0, EEmptyPackageName);
    assert!(is_valid_restrict_policy(policy), EInvalidPolicy);

    let current_policy = {
        let cap_ref: &mut UpgradeCap = account.borrow_managed_asset_mut(
            registry,
            UpgradeCapKey(name),
            executable,
            ExecutionProgressWitness {},
        );
        assert!(object::id(cap_ref) == expected_cap_id, EUpgradeCapIdMismatch);
        cap_ref.policy()
    };
    assert!(policy > current_policy, EPolicyShouldRestrict);

    let made_immutable = if (policy == immutable_policy()) {
        let cap: UpgradeCap = account.remove_managed_asset(
            registry,
            UpgradeCapKey(name),
            executable,
            ExecutionProgressWitness {},
        );
        package::make_immutable(cap);

        // Clean up orphaned rules data
        let UpgradeRules { delay_ms: _ } = account.remove_managed_data(
            registry,
            UpgradeRulesKey(name),
            executable,
            ExecutionProgressWitness {},
        );

        // Clean up index entry
        let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(
            registry,
            UpgradeIndexKey(),
            executable,
            ExecutionProgressWitness {},
        );
        index_mut.packages_info.remove(&name);

        true
    } else {
        let cap_mut: &mut UpgradeCap = account.borrow_managed_asset_mut(
            registry,
            UpgradeCapKey(name),
            executable,
            ExecutionProgressWitness {},
        );
        if (policy == package::additive_policy()) {
            cap_mut.only_additive_upgrades();
        } else {
            cap_mut.only_dep_upgrades();
        };
        false
    };

    event::emit(UpgradePolicyRestricted {
        account_id: object::id(account),
        package_name: name,
        old_policy: current_policy,
        new_policy: policy,
        made_immutable,
    });

    executable::increment_action_idx<_, PackageRestrict, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute `LockUpgradeCap` action: lock an UpgradeCap in the account via governance.
/// The UpgradeCap must already be present in executable_resources under resource_name.
/// ActionSpec data: name (String), delay_ms (u64), resource_name (String), expected_cap_id (ID encoded as address)
public fun do_init_lock_upgrade_cap<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<LockUpgradeCap>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let delay_ms = bcs::peel_u64(&mut reader);
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    bcs_validation::validate_all_bytes_consumed(reader);

    assert!(name.length() > 0, EEmptyPackageName);
    assert!(!has_cap(account, name), ELockAlreadyExists);

    let cap: UpgradeCap = executable_resources::take_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
    );
    let cap_id = object::id(&cap);
    assert!(cap_id == expected_cap_id, EUpgradeCapIdMismatch);
    let package_addr = cap.package().to_address();
    assert!(package_addr != @0x0, EInvalidPackageAddress);
    let policy = cap.policy();

    // Create or update upgrade index (use executable-tracked storage, not package_witness bypass)
    if (!account.has_managed_data(UpgradeIndexKey())) {
        account.add_managed_data(
            registry,
            UpgradeIndexKey(),
            UpgradeIndex { packages_info: vec_map::empty() },
            executable,
            ExecutionProgressWitness {},
        );
    };

    let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(
        registry,
        UpgradeIndexKey(),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(!index_mut.packages_info.contains(&name), EPackageNameAlreadyUsed);
    index_mut.packages_info.insert(name, package_addr);

    // Store the cap and rules (use executable-tracked storage)
    account.add_managed_asset(
        registry,
        UpgradeCapKey(name),
        cap,
        executable,
        ExecutionProgressWitness {},
    );
    account.add_managed_data(
        registry,
        UpgradeRulesKey(name),
        UpgradeRules { delay_ms },
        executable,
        ExecutionProgressWitness {},
    );

    event::emit(UpgradeCapLocked {
        account_id: object::id(account),
        package_name: name,
        package_addr,
        delay_ms,
        policy,
    });

    executable::increment_action_idx<_, LockUpgradeCap, _>(executable, registry, ExecutionProgressWitness {});
}

/// Execute `UnlockUpgradeCap` action: remove a locked UpgradeCap and store it in executable_resources.
/// Cleans up UpgradeRules and UpgradeIndex entry (inverse of lock).
/// ActionSpec data: name (String), resource_name (String), expected_cap_id (ID encoded as address)
public fun do_init_unlock_upgrade_cap<Outcome: store, IW: drop>(
    executable: &mut Executable<Outcome>,
    account: &mut Account,
    registry: &PackageRegistry,
    _intent_witness: IW,
    ctx: &mut TxContext,
) {
    executable.intent().assert_is_account(account.addr());

    let specs = executable.intent().action_specs();
    let action_spec = specs.borrow(executable.action_idx());
    account_protocol::action_validation::assert_action_type<UnlockUpgradeCap>(action_spec);

    let spec_version = intents::action_spec_version(action_spec);
    assert!(spec_version == 1, EUnsupportedActionVersion);

    let action_data = intents::action_spec_data(action_spec);
    let mut reader = bcs::new(*action_data);
    let name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let resource_name = std::string::utf8(bcs::peel_vec_u8(&mut reader));
    let expected_cap_id = bcs::peel_address(&mut reader).to_id();
    bcs_validation::validate_all_bytes_consumed(reader);
    assert!(name.length() > 0, EEmptyPackageName);

    // Remove the UpgradeCap
    let cap: UpgradeCap = account.remove_managed_asset(
        registry,
        UpgradeCapKey(name),
        executable,
        ExecutionProgressWitness {},
    );
    assert!(object::id(&cap) == expected_cap_id, EUpgradeCapIdMismatch);
    let package_addr = cap.package().to_address();

    // Clean up UpgradeRules
    let UpgradeRules { delay_ms: _ } = account.remove_managed_data(
        registry,
        UpgradeRulesKey(name),
        executable,
        ExecutionProgressWitness {},
    );

    // Clean up UpgradeIndex entry
    let index_mut: &mut UpgradeIndex = account.borrow_managed_data_mut(
        registry,
        UpgradeIndexKey(),
        executable,
        ExecutionProgressWitness {},
    );
    index_mut.packages_info.remove(&name);

    // Provide cap to executable_resources for a subsequent action to consume.
    executable_resources::provide_object(
        executable,
        registry,
        ExecutionProgressWitness {},
        resource_name,
        cap,
        ctx,
    );

    event::emit(UpgradeCapUnlocked {
        account_id: object::id(account),
        package_name: name,
        package_addr,
        resource_name,
    });

    executable::increment_action_idx<_, UnlockUpgradeCap, _>(executable, registry, ExecutionProgressWitness {});
}

// === Package Functions ===

/// Borrow the locked cap for a tracked package address.
public(package) fun borrow_cap(
    account: &Account,
    registry: &PackageRegistry,
    package_addr: address,
): &UpgradeCap {
    let name = get_package_name(account, registry, package_addr);
    account.borrow_managed_asset_with_package_witness(registry, UpgradeCapKey(name), version::current())
}
