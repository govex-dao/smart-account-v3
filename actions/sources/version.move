// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

// Portions of this file are derived from the account.tech Move Framework project.
// Those portions remain licensed under the Apache License, Version 2.0.

/// This module tracks the version of the package by implementing the version_witness type.
/// A new version type should be defined for each new version of the package.

module account_actions::actions_version;

use account_protocol::version_witness::{Self, VersionWitness};

// === Imports ===

// === Constants ===

const VERSION: u64 = 1; // bump this when the package is upgraded

// === Structs ===

// define a new version struct for each new version of the package
public struct V1 has drop {}

/// SECURITY: Package-private to prevent external PTBs from obtaining valid VersionWitnesses.
/// Only code within account_actions can create version witnesses for this package.
/// This prevents attackers from calling do_spend_unshared on unshared accounts.
public(package) fun current(): VersionWitness {
    version_witness::new(V1 {}) // modify with the new version struct
}

/// Test-only helper for integration tests in dependent packages.
/// Keeps `current()` package-private in production builds.
#[test_only]
public fun current_for_testing(): VersionWitness {
    current()
}

// === Public functions ===

public fun get(): u64 {
    VERSION
}
