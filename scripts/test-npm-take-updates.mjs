/**
 * Tests repo/npm-take-updates.mjs on made-up projects: what `task test:scripts` and CI's
 * tests job run. Each case writes a package.json, a package-lock.json and a folder under
 * node_modules for each lockfile entry into a scratch folder, runs the script there with the
 * case's updates, and checks which entries and folders it dropped and how package.json's
 * ranges rose. It prints ok or FAIL for each case, and exits 1 when any fails.
 */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const script = fileURLToPath(new URL('../repo/npm-take-updates.mjs', import.meta.url))

/** A scratch project holding these devDependencies and lockfile entries, keyed as npm keys them. */
function project(devDependencies, packages) {
  const dir = mkdtempSync(join(tmpdir(), 'npm-take-updates-'))
  const json = (value) => `${JSON.stringify(value, null, 2)}\n`
  writeFileSync(
    join(dir, 'package.json'),
    json({ name: 'example', private: true, devDependencies }),
  )
  const lock = {
    name: 'example',
    lockfileVersion: 3,
    requires: true,
    packages: { '': { name: 'example', devDependencies }, ...packages },
  }
  writeFileSync(join(dir, 'package-lock.json'), json(lock))
  for (const [key, entry] of Object.entries(packages)) {
    mkdirSync(join(dir, key), { recursive: true })
    writeFileSync(join(dir, key, 'package.json'), json({ name: key, version: entry.version }))
  }
  return dir
}

const types = {
  'node_modules/@eslint/core': {
    version: '1.2.1',
    dev: true,
    dependencies: { '@types/json-schema': '^7.0.15' },
  },
  'node_modules/@types/esrecurse': { version: '4.3.1', dev: true },
  'node_modules/@types/json-schema': { version: '7.0.15', dev: true },
  'node_modules/@types/node': {
    version: '26.6.10',
    dev: true,
    dependencies: { 'undici-types': '~8.9.0' },
  },
  'node_modules/@types/ws': { version: '8.18.1', dev: true, dependencies: { '@types/node': '*' } },
  'node_modules/eslint': {
    version: '10.15.0',
    dev: true,
    dependencies: { '@eslint/core': '1.2.1', '@types/esrecurse': '^4.3.1' },
  },
  'node_modules/undici-types': { version: '8.9.0', dev: true },
}

const tiptap = {
  'node_modules/@tiptap/core': { version: '3.35.0', peerDependencies: { '@tiptap/pm': '3.35.0' } },
  'node_modules/@tiptap/extension-bold': {
    version: '3.35.0',
    peerDependencies: { '@tiptap/core': '3.35.0' },
  },
  'node_modules/@tiptap/extension-bullet-list': {
    version: '3.35.0',
    peerDependencies: { '@tiptap/extension-list': '3.35.0' },
  },
  'node_modules/@tiptap/extension-list': {
    version: '3.35.0',
    peerDependencies: { '@tiptap/core': '3.35.0', '@tiptap/pm': '3.35.0' },
  },
  'node_modules/@tiptap/extension-ranged': {
    version: '2.1.0',
    peerDependencies: { '@tiptap/core': '^3.0.0' },
  },
  'node_modules/@tiptap/pm': {
    version: '3.35.0',
    dependencies: { 'prosemirror-model': '^1.25.0' },
  },
  'node_modules/@tiptap/starter-kit': {
    version: '3.35.0',
    dependencies: { '@tiptap/core': '3.35.0', '@tiptap/extension-bold': '3.35.0' },
  },
  'node_modules/@tiptap/starter-kit/node_modules/@tiptap/extension-bold': {
    version: '3.34.0',
    peerDependencies: { '@tiptap/core': '3.34.0' },
  },
  'node_modules/prosemirror-model': { version: '1.25.4' },
}

const cases = [
  {
    name: "@types/node moves alone, leaving the @types/ packages others need (@eslint/core's @types/json-schema)",
    devDependencies: { '@types/node': '^26.6.10', eslint: '^10.15.0' },
    packages: types,
    updates: ['@types/node@26.6.11'],
    dropped: ['node_modules/@types/node'],
    after: { '@types/node': '^26.6.11', eslint: '^10.15.0' },
  },
  {
    name: 'a package outside a scope moves alone, its scoped dependencies left, keeping its exact or ~ range',
    devDependencies: { '@types/node': '~26.6.10', eslint: '10.15.0' },
    packages: types,
    updates: ['@types/node@26.6.11', 'eslint@10.16.0'],
    dropped: ['node_modules/@types/node', 'node_modules/eslint'],
    after: { '@types/node': '~26.6.11', eslint: '10.16.0' },
  },
  {
    name: 'a scope that pins itself exactly moves together, every copy, through the packages between, ranges left',
    devDependencies: { '@tiptap/core': '^3.35.0', '@tiptap/starter-kit': '^3.35.0' },
    packages: tiptap,
    updates: ['@tiptap/core@3.35.1'],
    dropped: [
      'node_modules/@tiptap/core',
      'node_modules/@tiptap/extension-bold',
      'node_modules/@tiptap/extension-bullet-list',
      'node_modules/@tiptap/extension-list',
      'node_modules/@tiptap/pm',
      'node_modules/@tiptap/starter-kit',
      'node_modules/@tiptap/starter-kit/node_modules/@tiptap/extension-bold',
    ],
    after: { '@tiptap/core': '^3.35.1', '@tiptap/starter-kit': '^3.35.0' },
  },
]

/** Why a case's run differs from what it expects, or nothing when it matches. */
function check(test) {
  const dir = project(test.devDependencies, test.packages)
  try {
    execFileSync(process.execPath, [script, dir, ...test.updates], { stdio: 'pipe' })
    const lock = JSON.parse(readFileSync(join(dir, 'package-lock.json'), 'utf8'))
    const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    const problems = []
    for (const key of Object.keys(test.packages)) {
      const drop = test.dropped.includes(key)
      if (drop === key in lock.packages) {
        problems.push(`${key} ${drop ? 'kept' : 'dropped'} in the lockfile`)
      }
      if (drop === existsSync(join(dir, key))) {
        problems.push(`${key} ${drop ? 'kept' : 'removed'} in node_modules`)
      }
    }
    if (!('' in lock.packages)) problems.push("the lockfile's root entry dropped")
    if (JSON.stringify(pkg.devDependencies) !== JSON.stringify(test.after)) {
      problems.push(`package.json holds ${JSON.stringify(pkg.devDependencies)}`)
    }
    return problems.join('; ')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

let failed = 0
for (const test of cases) {
  try {
    const problem = check(test)
    if (problem) throw new Error(problem)
    console.log(`ok    ${test.name}`)
  } catch (error) {
    failed++
    console.error(`FAIL  ${test.name}: ${error instanceof Error ? error.message : String(error)}`)
  }
}
process.exit(failed ? 1 : 0)
