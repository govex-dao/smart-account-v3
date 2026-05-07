// Copyright (c) Govex DAO LLC
// SPDX-License-Identifier: BUSL-1.1

/// Centralized constants for Smart Account Actions
/// Uses public functions for upgradability (values can change on package upgrade)
module account_actions::actions_constants;

// === Memo ===

/// Maximum memo length in bytes
public fun max_memo_length(): u64 { 10000 }

// === Vault ===

/// Maximum number of vaults per account (prevents unbounded iteration)
public fun max_vaults(): u64 { 10 }

// === Stream/Vesting ===

/// Maximum beneficiaries per stream/vesting
/// Note: Canonical source is futarchy_one_shot_utils::constants::max_beneficiaries()
/// Duplicated here to avoid cross-package dependency for standalone use
public fun max_beneficiaries(): u64 { 100 }
