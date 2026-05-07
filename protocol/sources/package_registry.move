// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Unified registry for packages and their action decoders
///
/// This module combines package whitelisting and decoder registration into a single
/// coherent system, ensuring packages and their UI representations are always in sync.
///
/// Key improvements over separate Extensions + ActionDecoderRegistry:
/// - Atomic operations: Can't add package without declaring action types
/// - Single admin cap: Unified governance
/// - Enforced invariants: Package metadata always includes action types
/// - Better discoverability: Query which packages provide which actions
module account_protocol::package_registry;

use std::string::String;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

// === Errors ===

const EPackageNotFound: u64 = 0;
const EPackageAlreadyExists: u64 = 1;
const EActionTypeNotFound: u64 = 2;
const EActionTypeAlreadyRegistered: u64 = 3;
const EDuplicateActionTypeInInput: u64 = 6;
const ERegistryCapMismatch: u64 = 7;

fun assert_no_duplicate_action_types(action_types: &vector<String>) {
    let mut i = 0;
    while (i < action_types.length()) {
        let mut j = i + 1;
        while (j < action_types.length()) {
            let a = &action_types[i];
            let b = &action_types[j];
            assert!(*a != *b, EDuplicateActionTypeInInput);
            j = j + 1;
        };
        i = i + 1;
    };
}

// === Events ===

public struct PackageAdded has copy, drop {
    name: String,
    addr: address,
    version: u64,
    num_action_types: u64,
    category: String,
}

public struct PackageMetadataUpdated has copy, drop {
    name: String,
    num_action_types: u64,
    category: String,
}

// === Structs ===

/// Unified registry for packages and decoders
public struct PackageRegistry has key {
    id: UID,
    // Package tracking (name -> metadata)
    packages: Table<String, PackageMetadata>,
    // Reverse lookup (addr -> name)
    by_addr: Table<address, String>,
    // Registered version for O(1) validation (addr -> version)
    versions_by_addr: Table<address, u64>,
    // Action type tracking (action type name -> package that provides it)
    action_to_package: Table<String, String>,
}

/// Metadata for a registered package
public struct PackageMetadata has store {
    addr: address,
    version: u64,
    // Action types provided by this package (stored as String for serialization)
    action_types: vector<String>,
    // Package category (e.g., "core", "governance", "defi")
    category: String,
    // Optional description
    description: String,
}

/// Single admin capability for the unified registry.
///
/// SECURITY NOTE:
/// - `store` is required for governance custody patterns (managed-asset storage).
/// - Production admin APIs consume and return the cap by value, which prevents
///   direct use of a shared cap object.
/// - By-reference admin APIs are test-only helpers.
public struct PackageAdminCap has key, store {
    id: UID,
    registry_id: ID,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    let registry = PackageRegistry {
        id: object::new(ctx),
        packages: table::new(ctx),
        by_addr: table::new(ctx),
        versions_by_addr: table::new(ctx),
        action_to_package: table::new(ctx),
    };
    let registry_id = object::id(&registry);
    transfer::transfer(PackageAdminCap { id: object::new(ctx), registry_id }, ctx.sender());
    transfer::share_object(registry);
}

fun assert_admin_cap_for_registry(registry: &PackageRegistry, cap: &PackageAdminCap) {
    assert!(cap.registry_id == object::id(registry), ERegistryCapMismatch);
}

// === Admin Functions ===

fun add_package_impl(
    registry: &mut PackageRegistry,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
) {
    assert!(!registry.packages.contains(name), EPackageAlreadyExists);
    assert!(!registry.by_addr.contains(addr), EPackageAlreadyExists);
    assert_no_duplicate_action_types(&action_types);

    // Register action types -> package mapping
    // CRITICAL FIX: Assert on duplicates instead of silent skip
    let mut i = 0;
    while (i < action_types.length()) {
        let action_type = &action_types[i];
        assert!(!registry.action_to_package.contains(*action_type), EActionTypeAlreadyRegistered);
        registry.action_to_package.add(*action_type, name);
        i = i + 1;
    };

    // Create package metadata
    let metadata = PackageMetadata {
        addr,
        version,
        action_types,
        category,
        description,
    };

    // Add to registry
    registry.packages.add(name, metadata);
    registry.by_addr.add(addr, name);
    registry.versions_by_addr.add(addr, version);

    // Emit event
    event::emit(PackageAdded {
        name,
        addr,
        version,
        num_action_types: action_types.length(),
        category,
    });
}

/// Add a new package to the registry with its action types
/// This is an atomic operation - package and action type metadata are added together
///
/// Authorization: Requires PackageAdminCap ownership.
public fun add_package_with_cap(
    registry: &mut PackageRegistry,
    cap: PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
) : PackageAdminCap {
    assert_admin_cap_for_registry(registry, &cap);
    add_package_impl(registry, name, addr, version, action_types, category, description);
    cap
}

#[test_only]
public fun add_package(
    registry: &mut PackageRegistry,
    cap: &PackageAdminCap,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
) {
    assert_admin_cap_for_registry(registry, cap);
    add_package_impl(registry, name, addr, version, action_types, category, description);
}

/// Update package metadata (category, description, action types)
///
/// Authorization: Requires PackageAdminCap ownership.
fun update_package_metadata_impl(
    registry: &mut PackageRegistry,
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
) {
    assert!(registry.packages.contains(name), EPackageNotFound);
    assert_no_duplicate_action_types(&new_action_types);

    let metadata = registry.packages.borrow_mut(name);

    // Remove old action type mappings
    let old_action_types = &metadata.action_types;
    let mut i = 0;
    while (i < old_action_types.length()) {
        let action_type = &old_action_types[i];
        if (registry.action_to_package.contains(*action_type)) {
            registry.action_to_package.remove(*action_type);
        };
        i = i + 1;
    };

    // Add new action type mappings
    // CRITICAL FIX: Assert on duplicates instead of silent skip
    let mut j = 0;
    while (j < new_action_types.length()) {
        let action_type = &new_action_types[j];
        assert!(!registry.action_to_package.contains(*action_type), EActionTypeAlreadyRegistered);
        registry.action_to_package.add(*action_type, name);
        j = j + 1;
    };

    // Update metadata
    metadata.action_types = new_action_types;
    metadata.category = new_category;
    metadata.description = new_description;

    // Emit event
    event::emit(PackageMetadataUpdated {
        name,
        num_action_types: new_action_types.length(),
        category: new_category,
    });
}

public fun update_package_metadata_with_cap(
    registry: &mut PackageRegistry,
    cap: PackageAdminCap,
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
): PackageAdminCap {
    assert_admin_cap_for_registry(registry, &cap);
    update_package_metadata_impl(
        registry,
        name,
        new_action_types,
        new_category,
        new_description,
    );
    cap
}

#[test_only]
public fun update_package_metadata(
    registry: &mut PackageRegistry,
    cap: &PackageAdminCap,
    name: String,
    new_action_types: vector<String>,
    new_category: String,
    new_description: String,
) {
    assert_admin_cap_for_registry(registry, cap);
    update_package_metadata_impl(
        registry,
        name,
        new_action_types,
        new_category,
        new_description,
    );
}

// === View Functions ===

/// Check if a package exists
public fun has_package(registry: &PackageRegistry, name: String): bool {
    registry.packages.contains(name)
}

/// Check if an action type has a registered package
public fun has_action_type(registry: &PackageRegistry, action_type: String): bool {
    registry.action_to_package.contains(action_type)
}

/// Get which package provides an action type
public fun get_package_for_action(registry: &PackageRegistry, action_type: String): String {
    assert!(registry.action_to_package.contains(action_type), EActionTypeNotFound);
    *registry.action_to_package.borrow(action_type)
}

/// Get package metadata
public fun get_package_metadata(registry: &PackageRegistry, name: String): &PackageMetadata {
    assert!(registry.packages.contains(name), EPackageNotFound);
    registry.packages.borrow(name)
}

/// Get the registered address and version for a package
public fun get_latest_version(registry: &PackageRegistry, name: String): (address, u64) {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    (metadata.addr, metadata.version)
}

/// Check if a specific (name, addr, version) triple is valid
public fun is_valid_package(
    registry: &PackageRegistry,
    name: String,
    addr: address,
    version: u64,
): bool {
    if (!registry.packages.contains(name)) return false;
    if (!registry.versions_by_addr.contains(addr)) return false;
    if (!registry.by_addr.contains(addr)) return false;

    *registry.by_addr.borrow(addr) == name && *registry.versions_by_addr.borrow(addr) == version
}

/// Check if a package address exists in the registry
public fun contains_package_addr(registry: &PackageRegistry, addr: address): bool {
    registry.by_addr.contains(addr)
}

/// Get package name from address
public fun get_package_name(registry: &PackageRegistry, addr: address): String {
    assert!(registry.by_addr.contains(addr), EPackageNotFound);
    *registry.by_addr.borrow(addr)
}

/// Get all action types for a package
public fun get_action_types(registry: &PackageRegistry, name: String): &vector<String> {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.action_types
}

/// Get package category
public fun get_category(registry: &PackageRegistry, name: String): &String {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.category
}

/// Get package category by address (looks up name via by_addr, then gets category)
public fun get_category_by_addr(registry: &PackageRegistry, addr: address): String {
    let name = get_package_name(registry, addr);
    *get_category(registry, name)
}

/// Get package description
public fun get_description(registry: &PackageRegistry, name: String): &String {
    assert!(registry.packages.contains(name), EPackageNotFound);
    let metadata = registry.packages.borrow(name);
    &metadata.description
}

/// Get registry ID for dynamic field access (decoders)
public fun registry_id(registry: &PackageRegistry): &UID {
    &registry.id
}

/// Get mutable registry ID for adding decoders
/// Restricted to package to prevent arbitrary dynamic field manipulation
public(package) fun registry_id_mut(registry: &mut PackageRegistry): &mut UID {
    &mut registry.id
}

// === PackageMetadata Accessors ===

/// Get action types from metadata
public fun metadata_action_types(metadata: &PackageMetadata): &vector<String> {
    &metadata.action_types
}

/// Get category from metadata
public fun metadata_category(metadata: &PackageMetadata): &String {
    &metadata.category
}

/// Get description from metadata
public fun metadata_description(metadata: &PackageMetadata): &String {
    &metadata.description
}

/// Get address from metadata
public fun metadata_addr(metadata: &PackageMetadata): address {
    metadata.addr
}

/// Get version from metadata
public fun metadata_version(metadata: &PackageMetadata): u64 {
    metadata.version
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageRegistry {
    PackageRegistry {
        id: object::new(ctx),
        packages: table::new(ctx),
        by_addr: table::new(ctx),
        versions_by_addr: table::new(ctx),
        action_to_package: table::new(ctx),
    }
}

#[test_only]
public fun new_admin_cap_for_testing(registry: &PackageRegistry, ctx: &mut TxContext): PackageAdminCap {
    PackageAdminCap { id: object::new(ctx), registry_id: object::id(registry) }
}

#[test_only]
public fun add_for_testing(
    registry: &mut PackageRegistry,
    name: String,
    addr: address,
    version: u64,
) {
    // Bypass cap check for testing - directly add package
    assert!(!registry.packages.contains(name), EPackageAlreadyExists);
    assert!(!registry.by_addr.contains(addr), EPackageAlreadyExists);

    let metadata = PackageMetadata {
        addr,
        version,
        action_types: vector[], // empty action types for testing
        category: b"orchestrator".to_string(),
        description: b"test package".to_string(),
    };

    registry.packages.add(name, metadata);
    registry.by_addr.add(addr, name);
    registry.versions_by_addr.add(addr, version);
}

#[test_only]
public fun add_full_for_testing(
    registry: &mut PackageRegistry,
    name: String,
    addr: address,
    version: u64,
    action_types: vector<String>,
    category: String,
    description: String,
) {
    // Bypass cap check for testing - directly add package with full metadata
    assert!(!registry.packages.contains(name), EPackageAlreadyExists);
    assert!(!registry.by_addr.contains(addr), EPackageAlreadyExists);

    // Register action types -> package mapping
    let mut i = 0;
    while (i < action_types.length()) {
        let action_type = &action_types[i];
        assert!(!registry.action_to_package.contains(*action_type), EActionTypeAlreadyRegistered);
        registry.action_to_package.add(*action_type, name);
        i = i + 1;
    };

    let metadata = PackageMetadata {
        addr,
        version,
        action_types,
        category,
        description,
    };

    registry.packages.add(name, metadata);
    registry.by_addr.add(addr, name);
    registry.versions_by_addr.add(addr, version);
}

#[test_only]
public fun remove_for_testing(registry: &mut PackageRegistry, name: String) {
    // Bypass cap check for testing - directly remove package
    assert!(registry.packages.contains(name), EPackageNotFound);

    // Clean up action_to_package mappings
    let action_types = &registry.packages.borrow(name).action_types;
    let mut i = 0;
    while (i < action_types.length()) {
        let action_type = &action_types[i];
        if (registry.action_to_package.contains(*action_type)) {
            registry.action_to_package.remove(*action_type);
        };
        i = i + 1;
    };

    let metadata = registry.packages.remove(name);
    if (
        registry.by_addr.contains(metadata.addr) &&
        *registry.by_addr.borrow(metadata.addr) == name
    ) {
        registry.by_addr.remove(metadata.addr);
        registry.versions_by_addr.remove(metadata.addr);
    };

    let PackageMetadata { action_types: _, category: _, description: _, addr: _, version: _ } = metadata;
}

#[test_only]
public fun share_for_testing(registry: PackageRegistry) {
    transfer::share_object(registry);
}
