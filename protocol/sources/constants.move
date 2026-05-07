// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Centralized constants for the Smart Account Protocol
/// Uses public functions for upgradability (values can change on package upgrade)
module account_protocol::constants;

// === Intent/Action ===

/// Maximum size for action data in bytes (4KB)
public fun max_action_data_size(): u64 { 4096 }

/// Current action version for ActionSpec
public fun current_action_version(): u8 { 1 }

// === Authorization Levels ===

/// GLOBAL_ONLY: Only global registry packages allowed
public fun auth_level_global_only(): u8 { 0 }

/// WHITELIST: Global registry OR per-account whitelist (default)
public fun auth_level_whitelist(): u8 { 1 }

/// PERMISSIVE: Any action package allowed during intent staging, executable creation, and execution.
///
/// SECURITY:
/// - `_with_package_witness` functions (direct asset access) are NOT loosened — they use
///   `check_strict` which always requires global registry or per-account whitelist.
/// - PERMISSIVE only loosens the EXECUTION FLOW: any package's actions can execute within
///   approved intents. During execution, actions can call `remove_managed_asset`,
///   `remove_cap`, etc. through `assert_execution_authorized` which passes for any package.
/// - Governance (intent approval) is the sole defense against malicious actions.
/// - Immutable 3rd-party packages are auditable but cannot be patched if a vulnerability
///   is found later.
/// - Config mutation is additionally restricted to global registry packages even in
///   PERMISSIVE mode (see `config_mut_from_execution`).
///
/// Prefer WHITELIST mode for defense-in-depth.
public fun auth_level_permissive(): u8 { 2 }

// === Action Event Source Types ===

/// Source: Launchpad success actions
public fun source_launchpad_success(): u8 { 0 }

/// Source: Launchpad failure actions
public fun source_launchpad_failure(): u8 { 1 }

/// Source: Proposal actions
public fun source_proposal(): u8 { 2 }

/// Source: Factory initialization actions
public fun source_factory_init(): u8 { 3 }
