#!/usr/bin/env node
/**
 * Action Codegen Generator — Main Entry Point
 *
 * Usage:
 *   npm run generate                     — Generate all actions
 *   npm run generate:action memo         — Generate single action
 *   npx tsx src/generate.ts --action memo
 *   npx tsx src/generate.ts --dry-run    — Print output without writing
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { validateSchema, type ActionSchema } from './parse-schema.js';
import { generateInitActions, generateExecution } from './move-gen.js';
import {
  generateActionDef,
  generateComposerCase,
  generateExecutorCase,
} from './ts-gen.js';

// =============================================================================
// CONFIG
// =============================================================================

const CODEGEN_DIR = path.dirname(path.dirname(new URL(import.meta.url).pathname));
const ACTIONS_DIR = path.join(CODEGEN_DIR, 'actions');
const OUTPUT_DIR = path.join(CODEGEN_DIR, 'output');

// =============================================================================
// SCHEMA LOADING
// =============================================================================

function loadSchema(filePath: string): ActionSchema {
  const raw = fs.readFileSync(filePath, 'utf-8');
  const parsed = JSON.parse(raw);
  return validateSchema(parsed);
}

function loadAllSchemas(): ActionSchema[] {
  if (!fs.existsSync(ACTIONS_DIR)) {
    console.error(`Actions directory not found: ${ACTIONS_DIR}`);
    process.exit(1);
  }

  const files = fs.readdirSync(ACTIONS_DIR).filter((f) => f.endsWith('.json'));
  if (files.length === 0) {
    console.warn('No action schemas found in', ACTIONS_DIR);
    return [];
  }

  const schemas: ActionSchema[] = [];
  for (const file of files.sort()) {
    try {
      const schema = loadSchema(path.join(ACTIONS_DIR, file));
      schemas.push(schema);
    } catch (err) {
      console.error(`Error loading ${file}:`, err);
      process.exit(1);
    }
  }
  return schemas;
}

// =============================================================================
// OUTPUT WRITING
// =============================================================================

function ensureDir(dir: string): void {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

interface GeneratedOutput {
  schema: ActionSchema;
  initActionsMove: string;
  executionMove: string;
  actionDefTs: string;
  composerCaseTs: string;
  executorCaseTs: string;
}

function generateForSchema(schema: ActionSchema): GeneratedOutput {
  return {
    schema,
    initActionsMove: generateInitActions(schema),
    executionMove: generateExecution(schema),
    actionDefTs: generateActionDef(schema),
    composerCaseTs: generateComposerCase(schema),
    executorCaseTs: generateExecutorCase(schema),
  };
}

function writeOutput(output: GeneratedOutput, dryRun: boolean): void {
  const { schema } = output;

  const moveInitDir = path.join(OUTPUT_DIR, 'move', 'init');
  const moveLibDir = path.join(OUTPUT_DIR, 'move', 'lib');
  const tsDir = path.join(OUTPUT_DIR, 'ts');

  if (!dryRun) {
    ensureDir(moveInitDir);
    ensureDir(moveLibDir);
    ensureDir(tsDir);
  }

  const initFile = path.join(
    moveInitDir,
    `${schema.initModule ?? schema.module + '_init_actions'}.move`,
  );
  const execFile = path.join(moveLibDir, `${schema.module}.move`);
  const tsDefFile = path.join(tsDir, `${schema.id}_def.ts`);
  const tsComposerFile = path.join(tsDir, `${schema.id}_composer.ts`);
  const tsExecutorFile = path.join(tsDir, `${schema.id}_executor.ts`);

  if (dryRun) {
    console.log(`\n${'='.repeat(70)}`);
    console.log(`ACTION: ${schema.id} (${schema.name})`);
    console.log(`${'='.repeat(70)}`);

    console.log(`\n--- Move Init Actions (${initFile}) ---`);
    console.log(output.initActionsMove);

    console.log(`\n--- Move Execution (${execFile}) ---`);
    console.log(output.executionMove);

    console.log(`\n--- TS Action Definition ---`);
    console.log(output.actionDefTs);

    console.log(`\n--- TS Composer Case ---`);
    console.log(output.composerCaseTs);

    console.log(`\n--- TS Executor Case ---`);
    console.log(output.executorCaseTs);
  } else {
    fs.writeFileSync(initFile, output.initActionsMove);
    fs.writeFileSync(execFile, output.executionMove);
    fs.writeFileSync(tsDefFile, output.actionDefTs);
    fs.writeFileSync(tsComposerFile, output.composerCaseTs);
    fs.writeFileSync(tsExecutorFile, output.executorCaseTs);

    console.log(`  Generated: ${schema.id}`);
    console.log(`    Move init: ${path.relative(CODEGEN_DIR, initFile)}`);
    console.log(`    Move exec: ${path.relative(CODEGEN_DIR, execFile)}`);
    console.log(`    TS def:    ${path.relative(CODEGEN_DIR, tsDefFile)}`);
  }
}

function writeCombinedTs(outputs: GeneratedOutput[], dryRun: boolean): void {
  const tsDir = path.join(OUTPUT_DIR, 'ts');
  if (!dryRun) ensureDir(tsDir);

  // Combined action definitions
  const allDefs = outputs.map((o) => `  ${o.actionDefTs},`).join('\n');
  const defsFile = `// GENERATED by codegen — do not edit manually\n\nexport const GENERATED_ACTIONS = [\n${allDefs}\n];\n`;

  // Combined composer cases
  const allComposer = outputs.map((o) => `        ${o.composerCaseTs.replace(/\n/g, '\n        ')}`).join('\n');
  const composerFile = `// GENERATED by codegen — do not edit manually\n// Paste these cases into TransactionComposer.addActionToBuilder()\n\n${allComposer}\n`;

  // Combined executor cases
  const allExecutor = outputs.map((o) => `        ${o.executorCaseTs.replace(/\n/g, '\n        ')}`).join('\n');
  const executorFile = `// GENERATED by codegen — do not edit manually\n// Paste these cases into IntentExecutor.executeAction()\n\n${allExecutor}\n`;

  if (dryRun) {
    console.log('\n--- Combined Action Definitions ---');
    console.log(defsFile);
    console.log('\n--- Combined Composer Cases ---');
    console.log(composerFile);
    console.log('\n--- Combined Executor Cases ---');
    console.log(executorFile);
  } else {
    fs.writeFileSync(path.join(tsDir, '_all_definitions.ts'), defsFile);
    fs.writeFileSync(path.join(tsDir, '_all_composer_cases.ts'), composerFile);
    fs.writeFileSync(path.join(tsDir, '_all_executor_cases.ts'), executorFile);
    console.log(`\n  Combined TS files written to ${path.relative(CODEGEN_DIR, tsDir)}/`);
  }
}

// =============================================================================
// CLI
// =============================================================================

function main(): void {
  const args = process.argv.slice(2);
  const dryRun = args.includes('--dry-run');
  const actionFlag = args.indexOf('--action');
  const singleAction = actionFlag >= 0 ? args[actionFlag + 1] : undefined;

  console.log('Action Codegen Generator');
  console.log(`  Actions dir: ${path.relative(process.cwd(), ACTIONS_DIR)}`);
  console.log(`  Output dir:  ${path.relative(process.cwd(), OUTPUT_DIR)}`);
  if (dryRun) console.log('  Mode: DRY RUN (no files written)');
  if (singleAction) console.log(`  Single action: ${singleAction}`);
  console.log('');

  let schemas: ActionSchema[];

  if (singleAction) {
    const filePath = path.join(ACTIONS_DIR, `${singleAction}.json`);
    if (!fs.existsSync(filePath)) {
      console.error(`Schema file not found: ${filePath}`);
      process.exit(1);
    }
    schemas = [loadSchema(filePath)];
  } else {
    schemas = loadAllSchemas();
  }

  if (schemas.length === 0) {
    console.log('No schemas to process.');
    return;
  }

  console.log(`Processing ${schemas.length} action schema(s)...\n`);

  const outputs: GeneratedOutput[] = [];
  for (const schema of schemas) {
    const output = generateForSchema(schema);
    outputs.push(output);
    writeOutput(output, dryRun);
  }

  // Write combined TS files (only for full generation)
  if (!singleAction) {
    writeCombinedTs(outputs, dryRun);
  }

  console.log('\nDone!');
}

main();
