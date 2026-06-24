/**
 * Move Function Scanner
 *
 * Parses a Move source file to extract:
 * - Package address (from Move.toml)
 * - Module name (from module declaration)
 * - Function signature (params, type params, return type, visibility)
 *
 * Then auto-classifies params into ActionSchema fields.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import type { ActionSchema, FieldDef, FieldType, FieldRole, ExecutionDef, WrappedCallDef, WrappedCallArg } from './parse-schema.js';
import { snakeToPascal } from './parse-schema.js';

// =============================================================================
// TYPES
// =============================================================================

export interface ParsedParam {
  name: string;
  /** Raw Move type as written in source */
  rawType: string;
  /** Whether it's a reference (&T or &mut T) */
  isRef: boolean;
  /** Whether it's mutable (&mut T) */
  isMut: boolean;
  /** The inner type with & / &mut stripped */
  innerType: string;
}

export interface ParsedFunction {
  name: string;
  visibility: 'public' | 'public(package)' | 'entry' | 'private';
  typeParams: TypeParam[];
  params: ParsedParam[];
  returnType: string | null;
}

export interface TypeParam {
  name: string;
  constraints: string[]; // e.g. ['store', 'drop']
}

export interface ParsedModule {
  packageAddr: string;
  packageName: string;
  moduleName: string;
}

interface TypeResolver {
  typeAliases: Map<string, string>;
  moduleAliases: Map<string, string>;
}

export type ParamClassification =
  | { kind: 'clock' }
  | { kind: 'ctx' }
  | { kind: 'account'; mutable: boolean }
  | { kind: 'registry'; mutable: boolean }
  | { kind: 'bcs_field'; fieldType: FieldType }
  | { kind: 'external_object'; type: string; mutable: boolean }
  | { kind: 'resource_in_coin'; coinType: string }
  | { kind: 'resource_in_object'; objectType: string }
  | { kind: 'skip'; reason: string };

// =============================================================================
// MOVE.TOML PARSER
// =============================================================================

/**
 * Find the Move.toml by walking up from a .move file.
 * Returns the directory containing Move.toml.
 */
export function findMoveToml(moveFilePath: string): string | null {
  let dir = path.dirname(path.resolve(moveFilePath));
  for (let i = 0; i < 10; i++) {
    if (fs.existsSync(path.join(dir, 'Move.toml'))) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

/**
 * Parse Move.toml to extract package address and name.
 */
export function parseMoveToml(tomlPath: string): { name: string; address: string } {
  const content = fs.readFileSync(tomlPath, 'utf-8');

  // Extract [package] name
  const nameMatch = content.match(/^\s*name\s*=\s*"([^"]+)"/m);
  const name = nameMatch?.[1] ?? 'unknown';

  // Try published-at first (the on-chain address)
  const publishedMatch = content.match(/^\s*published-at\s*=\s*"(0x[0-9a-fA-F]+)"/m);
  if (publishedMatch) {
    return { name, address: publishedMatch[1] };
  }

  // Fall back to [addresses] section
  const addrSection = content.match(/\[addresses\]\s*\n([\s\S]*?)(?:\n\[|\n*$)/);
  if (addrSection) {
    const addrMatch = addrSection[1].match(/^\s*\w+\s*=\s*"(0x[0-9a-fA-F]+)"/m);
    if (addrMatch) {
      return { name, address: addrMatch[1] };
    }
  }

  return { name, address: '0x0' };
}

// =============================================================================
// MODULE PARSER
// =============================================================================

/**
 * Extract module declaration from a .move file.
 * Handles: `module addr::name;` and `module addr::name { ... }`
 */
export function parseModuleName(source: string): { package: string; module: string } | null {
  const match = source.match(/^\s*module\s+(\w+)::(\w+)\s*[;{]/m);
  if (!match) return null;
  return { package: match[1], module: match[2] };
}

// =============================================================================
// FUNCTION PARSER
// =============================================================================

/**
 * Extract a function signature from Move source by name.
 * Handles multi-line signatures.
 */
export function parseFunction(source: string, funcName: string): ParsedFunction | null {
  // Match function declaration - handles public, public(package), entry, and plain fun
  // The signature can span multiple lines until we find the opening {
  const patterns = [
    // public fun name<...>(...): RetType {
    new RegExp(
      `(public(?:\\(package\\))?\\s+)?(?:entry\\s+)?fun\\s+${escapeRegex(funcName)}\\s*(<[^>]*>)?\\s*\\(([\\s\\S]*?)\\)\\s*(?::\\s*([^{]+?))?\\s*\\{`,
      'm',
    ),
  ];

  for (const pattern of patterns) {
    const match = source.match(pattern);
    if (!match) continue;

    const visibilityStr = (match[1] ?? '').trim();
    const typeParamsStr = match[2] ?? '';
    const paramsStr = match[3] ?? '';
    const returnStr = (match[4] ?? '').trim() || null;

    // Determine visibility
    let visibility: ParsedFunction['visibility'];
    if (visibilityStr.includes('public(package)')) {
      visibility = 'public(package)';
    } else if (visibilityStr.includes('public')) {
      visibility = 'public';
    } else if (source.match(new RegExp(`entry\\s+fun\\s+${escapeRegex(funcName)}`))) {
      visibility = 'entry';
    } else {
      visibility = 'private';
    }

    // Parse type params
    const typeParams = parseTypeParams(typeParamsStr);

    // Parse params
    const params = parseParams(paramsStr);

    return {
      name: funcName,
      visibility,
      typeParams,
      params,
      returnType: returnStr,
    };
  }

  return null;
}

/**
 * List all public/entry functions in a Move file.
 */
export function listFunctions(source: string): string[] {
  const matches = source.matchAll(
    /(?:public(?:\(package\))?\s+)?(?:entry\s+)?fun\s+(\w+)\s*[<(]/gm,
  );
  const names: string[] = [];
  for (const m of matches) {
    names.push(m[1]);
  }
  return [...new Set(names)];
}

// =============================================================================
// TYPE PARAMS PARSER
// =============================================================================

function parseTypeParams(str: string): TypeParam[] {
  if (!str) return [];
  // Strip < >
  const inner = str.replace(/^</, '').replace(/>$/, '').trim();
  if (!inner) return [];

  const params: TypeParam[] = [];
  // Split by comma, but respect nested < >
  for (const part of splitTopLevel(inner, ',')) {
    const trimmed = part.trim();
    // Handle "phantom CoinType" or "T: store + drop" or just "T"
    const phantomStripped = trimmed.replace(/^phantom\s+/, '');
    const colonIdx = phantomStripped.indexOf(':');
    if (colonIdx >= 0) {
      const name = phantomStripped.slice(0, colonIdx).trim();
      const constraintsStr = phantomStripped.slice(colonIdx + 1).trim();
      const constraints = constraintsStr.split('+').map((c) => c.trim()).filter(Boolean);
      params.push({ name, constraints });
    } else {
      params.push({ name: phantomStripped.trim(), constraints: [] });
    }
  }
  return params;
}

// =============================================================================
// PARAMS PARSER
// =============================================================================

function parseParams(str: string): ParsedParam[] {
  const trimmed = str.trim();
  if (!trimmed) return [];

  const params: ParsedParam[] = [];
  for (const part of splitTopLevel(trimmed, ',')) {
    const p = part.trim();
    if (!p) continue;

    // Format: "name: Type" or "mut name: Type"
    const colonIdx = p.indexOf(':');
    if (colonIdx < 0) continue;

    let name = p.slice(0, colonIdx).trim();
    // Strip 'mut' keyword from name
    name = name.replace(/^mut\s+/, '');

    const rawType = p.slice(colonIdx + 1).trim();

    // Detect reference
    const isRef = rawType.startsWith('&');
    const isMut = rawType.startsWith('&mut ');
    let innerType = rawType;
    if (isMut) {
      innerType = rawType.slice(5).trim();
    } else if (isRef) {
      innerType = rawType.slice(1).trim();
    }

    params.push({ name, rawType, isRef, isMut, innerType });
  }
  return params;
}

// =============================================================================
// PARAM CLASSIFIER
// =============================================================================

/**
 * Classify a parsed Move param into an ActionSchema field category.
 */
export function classifyParam(param: ParsedParam): ParamClassification {
  const { innerType, isMut, isRef } = param;

  // Clock
  if (innerType === 'Clock' || innerType === 'sui::clock::Clock' || innerType === 'clock::Clock') {
    return { kind: 'clock' };
  }

  // TxContext
  if (innerType === 'TxContext' || innerType === 'tx_context::TxContext' || innerType === 'sui::tx_context::TxContext') {
    return { kind: 'ctx' };
  }

  if (isRef && isAccountType(innerType)) {
    return { kind: 'account', mutable: isMut };
  }

  if (isRef && isPackageRegistryType(innerType)) {
    return { kind: 'registry', mutable: isMut };
  }

  // Coin<X> (not a reference) → resource_in_coin
  const coinMatch = innerType.match(/^(?:sui::)?(?:coin::)?Coin<(.+)>$/);
  if (coinMatch && !isRef) {
    return { kind: 'resource_in_coin', coinType: coinMatch[1] };
  }

  // Primitives (not references) → BCS field from staged spec
  if (!isRef) {
    const fieldType = primitiveToFieldType(innerType);
    if (fieldType) {
      return { kind: 'bcs_field', fieldType };
    }
  }

  // References to known framework types we skip
  if (isRef && isFrameworkType(innerType)) {
    return { kind: 'skip', reason: `Framework type: ${innerType}` };
  }

  // Reference to struct → external_object (shared object passed from PTB, ID validated)
  if (isRef) {
    return { kind: 'external_object', type: innerType, mutable: isMut };
  }

  // Non-reference, non-primitive struct by value → resource_in_object
  // Assumed to come from executable_resources (produced by a prior action in the chain)
  return { kind: 'resource_in_object', objectType: innerType };
}

/**
 * Classify return type to detect resource_out (Coin outputs).
 */
export function classifyReturn(returnType: string | null): { kind: 'coin'; coinType: string } | { kind: 'object'; objectType: string } | null {
  if (!returnType) return null;
  const normalized = returnType.trim();
  const coinMatch = normalized.match(/^(?:sui::)?(?:coin::)?Coin<(.+)>$/);
  if (coinMatch) {
    return { kind: 'coin', coinType: coinMatch[1] };
  }
  if (
    !normalized.includes('(')
    && !primitiveToFieldType(normalized)
    && normalized !== '()'
  ) {
    return { kind: 'object', objectType: normalized };
  }
  return null;
}

// =============================================================================
// SCHEMA GENERATOR
// =============================================================================

export interface ScanResult {
  module: ParsedModule;
  func: ParsedFunction;
  schema: ActionSchema;
  warnings: string[];
}

/**
 * Scan a Move file + function and produce an ActionSchema.
 */
export function scanAndGenerate(
  moveFilePath: string,
  funcName: string,
  actionId?: string,
): ScanResult {
  const warnings: string[] = [];

  // 1. Find and parse Move.toml
  const pkgDir = findMoveToml(moveFilePath);
  if (!pkgDir) {
    throw new Error(`Could not find Move.toml for ${moveFilePath}`);
  }
  const tomlInfo = parseMoveToml(path.join(pkgDir, 'Move.toml'));

  // 2. Parse module name
  const source = fs.readFileSync(moveFilePath, 'utf-8');
  const moduleInfo = parseModuleName(source);
  if (!moduleInfo) {
    throw new Error(`Could not parse module declaration in ${moveFilePath}`);
  }
  const typeResolver = parseUseAliases(source);

  const parsedModule: ParsedModule = {
    packageAddr: tomlInfo.address,
    packageName: tomlInfo.name,
    moduleName: moduleInfo.module,
  };

  // 3. Parse function
  const func = parseFunction(source, funcName);
  if (!func) {
    const available = listFunctions(source);
    throw new Error(
      `Function '${funcName}' not found in ${moveFilePath}.\nAvailable: ${available.join(', ')}`,
    );
  }

  // 4. Check visibility
  if (func.visibility === 'public(package)') {
    throw new Error(
      `Function '${funcName}' is public(package) — cannot be called from PTB`,
    );
  }
  if (func.visibility === 'private') {
    throw new Error(
      `Function '${funcName}' is private — cannot be called from PTB`,
    );
  }
  const reservedTypeParams = func.typeParams
    .map((tp) => tp.name)
    .filter((name) => name === 'Outcome' || name === 'IW');
  if (reservedTypeParams.length > 0) {
    throw new Error(
      `Function '${funcName}' uses reserved wrapper type parameter(s): ${reservedTypeParams.join(', ')}`,
    );
  }

  // 5. Classify params and build wrapped call args
  const fields: FieldDef[] = [];
  const externalObjects: ActionSchema['execution']['externalObjects'] = [];
  const execution: ExecutionDef = {};
  const phantomTypes: string[] = [];
  const wrappedArgs: WrappedCallArg[] = [];
  const localTypeParams = new Set(func.typeParams.map((tp) => tp.name));

  for (const param of func.params) {
    const classification = classifyParam(param);

    switch (classification.kind) {
      case 'clock':
        execution.needsClock = true;
        wrappedArgs.push({ source: 'clock', varName: 'clock' });
        break;

      case 'ctx':
        execution.needsCtx = true;
        wrappedArgs.push({ source: 'ctx', varName: 'ctx' });
        break;

      case 'account':
        execution.needsAccount = true;
        wrappedArgs.push({ source: 'account', varName: 'account', mutable: classification.mutable });
        break;

      case 'registry':
        execution.needsRegistry = true;
        wrappedArgs.push({ source: 'registry', varName: 'registry', mutable: classification.mutable });
        break;

      case 'bcs_field':
        fields.push({
          name: param.name,
          type: classification.fieldType,
          description: param.name,
        });
        wrappedArgs.push({ source: 'bcs_field', varName: param.name });
        break;

      case 'resource_in_coin': {
        // Use param name as resource name field, prefixed for the take_coin variable
        const resFieldName = `${param.name}_resource`;
        const coinType = qualifyType(classification.coinType, moduleInfo, typeResolver, localTypeParams);
        fields.push({
          name: resFieldName,
          type: 'String',
          role: 'resource_in_coin',
          moveType: `Coin<${coinType}>`,
          description: `Resource name for input Coin<${classification.coinType}>`,
        });
        wrappedArgs.push({ source: 'resource_in_coin', varName: param.name });
        break;
      }

      case 'resource_in_object': {
        const resFieldName = `${param.name}_resource`;
        const qualifiedType = qualifyType(classification.objectType, moduleInfo, typeResolver, localTypeParams);
        fields.push({
          name: resFieldName,
          type: 'String',
          role: 'resource_in_object',
          moveType: qualifiedType,
          description: `Resource name for input ${qualifiedType}`,
        });
        wrappedArgs.push({ source: 'resource_in_object', varName: param.name });
        break;
      }

      case 'external_object': {
        const idFieldName = `${param.name}_id`;
        const qualifiedType = qualifyType(classification.type, moduleInfo, typeResolver, localTypeParams);
        fields.push({
          name: idFieldName,
          type: 'ID',
          role: 'external_object',
          description: `ID of ${qualifiedType}`,
        });
        externalObjects!.push({
          name: param.name,
          type: qualifiedType,
          idField: idFieldName,
          mutable: classification.mutable,
        });
        wrappedArgs.push({ source: 'external_object', varName: param.name, mutable: classification.mutable });
        break;
      }

      case 'skip':
        warnings.push(`Skipped param '${param.name}': ${classification.reason}`);
        break;
    }
  }

  // Preserve constraints for every wrapped-call type param, including account Config.
  const typeParamConstraints = Object.fromEntries(
    func.typeParams
      .filter((tp) => tp.constraints.length > 0)
      .map((tp) => [tp.name, tp.constraints]),
  );
  if (Object.keys(typeParamConstraints).length > 0) {
    execution.typeParamConstraints = typeParamConstraints;
  }

  // Marker phantoms are the action identity. Account Config is an execution context
  // type, so keep it in wrappedCall.typeParams but do not encode it in ActionSpec.
  for (const tp of func.typeParams) {
    if (execution.needsAccount && tp.name === 'Config') continue;
    phantomTypes.push(tp.name);
  }

  // Check return type for resource_out
  const returnOut = classifyReturn(func.returnType);
  if (returnOut?.kind === 'coin') {
    const coinType = qualifyType(returnOut.coinType, moduleInfo, typeResolver, localTypeParams);
    fields.push({
      name: 'resource_out',
      type: 'String',
      role: 'resource_out_coin',
      moveType: `Coin<${coinType}>`,
      description: `Resource name for output Coin<${returnOut.coinType}>`,
    });
  } else if (returnOut?.kind === 'object') {
    const qualifiedType = qualifyType(returnOut.objectType, moduleInfo, typeResolver, localTypeParams);
    fields.push({
      name: 'resource_out',
      type: 'String',
      role: 'resource_out_object',
      moveType: qualifiedType,
      description: `Resource name for output ${qualifiedType}`,
    });
  }

  if (externalObjects!.length > 0) {
    execution.externalObjects = externalObjects;
  }

  // Build action ID
  const id = actionId ?? `${moduleInfo.module}_${funcName}`;
  const markerName = snakeToPascal(id);

  // Build the wrapped call target
  const callTarget = `${moduleInfo.package}::${moduleInfo.module}::${funcName}`;
  const wrappedCall: WrappedCallDef = {
    target: callTarget,
    typeParams: func.typeParams.map((tp) => tp.name),
    args: wrappedArgs,
    ...(returnOut ? { returnType: func.returnType! } : {}),
  };

  const schema: ActionSchema = {
    id,
    name: `${snakeToPascal(moduleInfo.module)} ${snakeToPascal(funcName)}`,
    category: 'config', // default, user can change
    package: 'accountActions', // default, user can change
    module: `${moduleInfo.module}_wrapper`,
    marker: {
      name: markerName,
      ...(phantomTypes.length > 0 ? { phantomTypes } : {}),
    },
    fields,
    execution,
    version: 1,
    launchpadSupported: false,
    proposalSupported: true,
    description: `Wrapper for ${tomlInfo.name}::${moduleInfo.module}::${funcName}`,
    wrappedCall,
  };

  return { module: parsedModule, func, schema, warnings };
}

// =============================================================================
// HELPERS
// =============================================================================

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Split string by delimiter, respecting nested < > */
function splitTopLevel(str: string, delim: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = '';
  for (const ch of str) {
    if (ch === '<') depth++;
    else if (ch === '>') depth--;

    if (ch === delim && depth === 0) {
      parts.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.trim()) parts.push(current);
  return parts;
}

/** Map Move primitive types to schema FieldType */
function primitiveToFieldType(moveType: string): FieldType | null {
  const map: Record<string, FieldType> = {
    'u8': 'u8',
    'u64': 'u64',
    'u128': 'u128',
    'bool': 'bool',
    'address': 'address',
    'String': 'String',
    'std::string::String': 'String',
    'string::String': 'String',
    'ID': 'ID',
    'object::ID': 'ID',
    'sui::object::ID': 'ID',
    'vector<u8>': 'vector<u8>',
    'vector<address>': 'vector<address>',
  };

  // Direct match
  if (map[moveType]) return map[moveType];

  // Option<X>
  const optMatch = moveType.match(/^(?:std::)?(?:option::)?Option<(.+)>$/);
  if (optMatch) {
    const inner = optMatch[1].trim();
    const optKey = `Option<${primitiveToFieldType(inner) ?? inner}>` as FieldType;
    if (['Option<u64>', 'Option<u128>', 'Option<bool>', 'Option<String>'].includes(optKey)) {
      return optKey;
    }
  }

  return null;
}

function parseUseAliases(source: string): TypeResolver {
  const resolver: TypeResolver = {
    typeAliases: new Map(),
    moduleAliases: new Map(),
  };

  for (const match of source.matchAll(/^\s*use\s+([^;]+);/gm)) {
    const spec = match[1].trim();
    const groupMatch = spec.match(/^(.*?)::\{([\s\S]*)\}$/);
    if (groupMatch) {
      const prefix = groupMatch[1].trim();
      for (const entry of splitTopLevel(groupMatch[2], ',')) {
        addGroupedUseAlias(resolver, prefix, entry.trim());
      }
      continue;
    }

    addDirectUseAlias(resolver, spec);
  }

  return resolver;
}

function addGroupedUseAlias(resolver: TypeResolver, prefix: string, entry: string): void {
  if (!entry) return;
  const { imported, alias } = splitUseAlias(entry);
  if (imported === 'Self') {
    const moduleName = prefix.split('::').at(-1);
    if (moduleName) resolver.moduleAliases.set(alias ?? moduleName, prefix);
    return;
  }

  resolver.typeAliases.set(alias ?? imported, `${prefix}::${imported}`);
}

function addDirectUseAlias(resolver: TypeResolver, spec: string): void {
  const { imported, alias } = splitUseAlias(spec);
  const parts = imported.split('::');
  if (parts.length < 2) return;

  const localName = alias ?? parts.at(-1)!;
  if (parts.length === 2) {
    resolver.moduleAliases.set(localName, imported);
    return;
  }

  resolver.typeAliases.set(localName, imported);
}

function splitUseAlias(spec: string): { imported: string; alias?: string } {
  const aliasMatch = spec.match(/^(.*?)\s+as\s+(\w+)$/);
  if (!aliasMatch) return { imported: spec.trim() };
  return { imported: aliasMatch[1].trim(), alias: aliasMatch[2].trim() };
}

/**
 * Qualify a type with its source module path if it's not already qualified.
 * e.g. "Pool<CoinIn, CoinOut>" → "test_dex::router::Pool<CoinIn, CoinOut>"
 */
function qualifyType(
  type: string,
  moduleInfo: { package: string; module: string },
  resolver?: TypeResolver,
  localTypeParams: Set<string> = new Set(),
): string {
  const trimmed = type.trim();
  const genericStart = trimmed.indexOf('<');

  if (genericStart < 0) {
    return qualifyBaseType(trimmed, moduleInfo, resolver, localTypeParams);
  }

  const genericEnd = trimmed.lastIndexOf('>');
  if (genericEnd < genericStart) {
    return qualifyBaseType(trimmed, moduleInfo, resolver, localTypeParams);
  }

  const baseType = trimmed.slice(0, genericStart).trim();
  const genericArgs = trimmed.slice(genericStart + 1, genericEnd);
  const qualifiedBase = qualifyBaseType(baseType, moduleInfo, resolver, localTypeParams);
  const qualifiedArgs = splitTopLevel(genericArgs, ',')
    .map((arg) => qualifyType(arg, moduleInfo, resolver, localTypeParams))
    .join(', ');

  return `${qualifiedBase}<${qualifiedArgs}>${trimmed.slice(genericEnd + 1)}`;
}

function qualifyBaseType(
  baseType: string,
  moduleInfo: { package: string; module: string },
  resolver?: TypeResolver,
  localTypeParams: Set<string> = new Set(),
): string {
  if (localTypeParams.has(baseType) || primitiveToFieldType(baseType) || isBuiltinGenericBase(baseType)) {
    return baseType;
  }

  if (!baseType.includes('::')) {
    const aliasedType = resolver?.typeAliases.get(baseType);
    if (aliasedType) return aliasedType;
    return `${moduleInfo.package}::${moduleInfo.module}::${baseType}`;
  }

  const parts = baseType.split('::');
  if (parts.length === 2) {
    const aliasedModule = resolver?.moduleAliases.get(parts[0]);
    if (aliasedModule) return `${aliasedModule}::${parts[1]}`;
  }

  // Already fully qualified, or no import alias exists.
  return baseType;
}

function isBuiltinGenericBase(type: string): boolean {
  return type === 'Option' || type === 'std::option::Option' || type === 'vector';
}

/** Check if a type is a framework type that should be skipped (not stored in ActionSpec) */
function isFrameworkType(type: string): boolean {
  const frameworks = [
    'Executable',
    'executable::Executable',
    'Expired',
    'intents::Expired',
  ];
  // Check if the type starts with any framework type (handles generics)
  return frameworks.some((f) => type === f || type.startsWith(f + '<'));
}

function isAccountType(type: string): boolean {
  return type === 'Account' || type === 'account::Account' || type === 'account_protocol::account::Account';
}

function isPackageRegistryType(type: string): boolean {
  return (
    type === 'PackageRegistry'
    || type === 'package_registry::PackageRegistry'
    || type === 'account_protocol::package_registry::PackageRegistry'
  );
}
