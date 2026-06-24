/**
 * TypeScript Code Generators
 *
 * Generates action definitions, composer cases, and executor cases
 * from action schemas.
 */

import {
  ActionSchema,
  TS_TYPE_MAP,
  getInitModule,
  getSpecFunctionName,
  getExecFunctionName,
  getPhantomTypes,
  getMarkerTypeBase,
  snakeToCamel,
  packageToMoveAddr,
} from './parse-schema.js';

// =============================================================================
// ACTION DEFINITION GENERATOR
// =============================================================================

/**
 * Generate a TypeScript ActionDefinition object literal
 * (matching the interface in action-definitions.ts)
 */
export function generateActionDef(schema: ActionSchema): string {
  const lines: string[] = [];
  const pkgAddr = packageToMoveAddr(schema.package);
  const initModule = getInitModule(schema);
  const specFn = getSpecFunctionName(schema);
  const execFn = getExecFunctionName(schema);
  const markerTypeBase = getMarkerTypeBase(schema);
  const phantomTypes = getPhantomTypes(schema);

  lines.push('{');
  lines.push(`  id: '${schema.id}',`);
  lines.push(`  name: '${schema.name}',`);
  lines.push(`  category: '${schema.category}',`);
  lines.push(`  package: '${schema.package}',`);
  lines.push(`  stagingModule: '${initModule}',`);
  lines.push(`  stagingFunction: '${specFn}',`);
  lines.push(`  executionModule: '${schema.module}',`);
  lines.push(`  executionFunction: '${execFn}',`);
  lines.push(`  markerType: '${markerTypeBase}',`);

  if (phantomTypes.length > 0) {
    lines.push(`  typeParams: [${phantomTypes.map((t) => `'${t}'`).join(', ')}],`);
  }

  // Params
  lines.push('  params: [');
  for (const field of schema.fields) {
    const tsParamType = fieldTypeToParamType(field.type);
    lines.push(`    { name: '${snakeToCamel(field.name)}', type: '${tsParamType}', description: '${field.description ?? field.name}' },`);
  }
  lines.push('  ],');

  lines.push(`  description: '${schema.description ?? schema.name}',`);
  lines.push(`  launchpadSupported: ${schema.launchpadSupported},`);
  lines.push(`  proposalSupported: ${schema.proposalSupported},`);
  lines.push('}');

  return lines.join('\n');
}

// =============================================================================
// COMPOSER CASE GENERATOR (STAGING)
// =============================================================================

/**
 * Generate a switch case for TransactionComposer.addActionToBuilder()
 * This is the staging side — builds the PTB call to add_*_spec
 */
export function generateComposerCase(schema: ActionSchema): string {
  const lines: string[] = [];
  const initModule = getInitModule(schema);
  const specFn = getSpecFunctionName(schema);
  const phantomTypes = getPhantomTypes(schema);

  lines.push(`case '${schema.id}':`);
  lines.push('    tx.moveCall({');
  lines.push(`        target: \`\${pkg}::${initModule}::${specFn}\`,`);

  // Type arguments
  if (phantomTypes.length > 0) {
    const typeArgs = phantomTypes.map((t) => {
      const camel = t.charAt(0).toLowerCase() + t.slice(1);
      return `action.${camel}`;
    });
    lines.push(`        typeArguments: [${typeArgs.join(', ')}],`);
  }

  // Arguments
  lines.push('        arguments: [');
  lines.push('            builder,');
  for (const field of schema.fields) {
    const camelName = snakeToCamel(field.name);
    const tsMapping = TS_TYPE_MAP[field.type];
    lines.push(`            ${tsMapping.txPure(`action.${camelName}`)},`);
  }
  lines.push('        ],');
  lines.push('    });');
  lines.push('    break;');

  return lines.join('\n');
}

// =============================================================================
// EXECUTOR CASE GENERATOR (EXECUTION)
// =============================================================================

/**
 * Generate a switch case for IntentExecutor.executeAction()
 * This is the execution side — builds the PTB call to do_init_*
 */
export function generateExecutorCase(schema: ActionSchema): string {
  const lines: string[] = [];
  const execFn = getExecFunctionName(schema);
  const phantomTypes = getPhantomTypes(schema);
  const exec = schema.execution;

  lines.push(`case '${schema.id}':`);
  lines.push('    tx.moveCall({');
  lines.push(`        target: \`\${pkg}::${schema.module}::${execFn}\`,`);

  // Type arguments: [configType, outcomeType, ...phantomTypes, witnessType]
  const typeArgs: string[] = [];
  if (exec.needsAccount) {
    typeArgs.push('configType');
  }
  typeArgs.push('outcomeType');
  for (const pt of phantomTypes) {
    if (exec.needsAccount && pt === 'Config') continue;
    const camel = pt.charAt(0).toLowerCase() + pt.slice(1);
    typeArgs.push(`action.${camel}`);
  }
  typeArgs.push('witnessType');
  lines.push(`        typeArguments: [${typeArgs.join(', ')}],`);

  // Arguments
  lines.push('        arguments: [');
  lines.push('            executable,');
  if (exec.needsAccount) {
    lines.push('            account,');
  }
  lines.push('            registry,');

  // External objects from PTB
  if (exec.externalObjects) {
    for (const obj of exec.externalObjects) {
      const camelField = snakeToCamel(obj.idField);
      lines.push(`            tx.object(action.${camelField}),`);
    }
  }

  if (exec.needsClock) {
    lines.push('            clock,');
  }

  lines.push('            intentWitness,');

  if (exec.needsCtx) {
    // ctx is usually implicit in Sui PTBs
  }

  lines.push('        ],');
  lines.push('    });');
  lines.push('    break;');

  return lines.join('\n');
}

// =============================================================================
// HELPERS
// =============================================================================

/** Map codegen FieldType to SDK ParamType */
function fieldTypeToParamType(fieldType: string): string {
  const map: Record<string, string> = {
    'u8': 'u8',
    'u64': 'u64',
    'u128': 'u128',
    'bool': 'bool',
    'String': 'string',
    'address': 'address',
    'ID': 'id',
    'Option<u64>': 'option<u64>',
    'Option<u128>': 'option<u128>',
    'Option<bool>': 'option<bool>',
    'Option<String>': 'option<string>',
    'vector<u8>': 'vector<u8>',
    'vector<String>': 'vector<string>',
    'vector<address>': 'vector<address>',
  };
  return map[fieldType] ?? fieldType.toLowerCase();
}
