/**
 * Type-checks a front end's Vitest specs under their own tsconfig.vitest.json, the check
 * web.yml runs after the app's scripts:
 *
 *   node ../shared/test/web/typecheck-specs.mjs [front-end folder]
 *
 * An app with Vitest specs (vitest in its package.json and a *.spec or *.test file under
 * src/) needs a tsconfig.vitest.json that extends @jwill89/lint-web/tsconfig.vitest.json
 * and takes in every spec. Its specs are then checked with vue-tsc where the app has it,
 * else with tsc, both from the app's own install. An app with no Vitest, or no specs yet,
 * passes with a note.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'

const base = '@jwill89/lint-web/tsconfig.vitest.json'
const configName = 'tsconfig.vitest.json'

const fail = (message) => {
  console.error(`typecheck-specs: ${message}`)
  process.exit(1)
}

const root = path.resolve(process.argv[2] ?? '.')
const manifestPath = path.join(root, 'package.json')
if (!existsSync(manifestPath)) {
  fail(`no package.json in ${root}.`)
}
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
const listed = { ...manifest.dependencies, ...manifest.devDependencies }
if (!('vitest' in listed)) {
  console.log('typecheck-specs: no Vitest in package.json; nothing to check.')
  process.exit(0)
}

const specs = []
const walk = (folder) => {
  for (const entry of readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name)
    if (entry.isDirectory()) {
      if (entry.name !== 'node_modules') {
        walk(full)
      }
    } else if (/\.(spec|test)\.(ts|tsx|mts)$/.test(entry.name)) {
      specs.push(full)
    }
  }
}
const src = path.join(root, 'src')
if (existsSync(src)) {
  walk(src)
}
if (specs.length === 0) {
  console.log('typecheck-specs: no specs under src/ yet; nothing to check.')
  process.exit(0)
}

const configPath = path.join(root, configName)
if (!existsSync(configPath)) {
  fail(`the app has Vitest specs but no ${configName}. Add one that extends ${base}.`)
}

// The app's own TypeScript reads the config, comments and all, as tsc would.
const require = createRequire(manifestPath)
let ts
try {
  ts = require('typescript')
} catch {
  fail('TypeScript is not installed in the app; run npm ci first.')
}
const read = ts.readConfigFile(configPath, ts.sys.readFile)
if (read.error) {
  fail(ts.flattenDiagnosticMessageText(read.error.messageText, '\n'))
}
const extended = [read.config.extends ?? []].flat()
if (!extended.includes(base)) {
  fail(`${configName} must extend ${base} (it extends ${JSON.stringify(read.config.extends ?? null)}).`)
}
const parsed = ts.parseJsonConfigFileContent(read.config, ts.sys, root, undefined, configPath)
const included = new Set(parsed.fileNames.map((file) => path.resolve(file)))
const missing = specs.filter((spec) => !included.has(path.resolve(spec)))
if (missing.length > 0) {
  const list = missing.map((spec) => `  ${path.relative(root, spec)}`).join('\n')
  fail(`${configName} leaves out these specs, so nothing type-checks them:\n${list}`)
}

// A package's command, from its package.json's bin, found as npm finds it: in the
// nearest node_modules up from the app.
const findBin = (pkg) => {
  for (let dir = root; ; dir = path.dirname(dir)) {
    const folder = path.join(dir, 'node_modules', pkg)
    const file = path.join(folder, 'package.json')
    if (existsSync(file)) {
      const bin = JSON.parse(readFileSync(file, 'utf8')).bin
      const target = typeof bin === 'string' ? bin : bin?.[pkg === 'typescript' ? 'tsc' : pkg]
      if (target) {
        return path.join(folder, target)
      }
    }
    if (path.dirname(dir) === dir) {
      return undefined
    }
  }
}
const name = findBin('vue-tsc') ? 'vue-tsc' : 'tsc'
const checker = findBin(name === 'tsc' ? 'typescript' : 'vue-tsc')
if (!checker) {
  fail('neither vue-tsc nor tsc is installed in the app.')
}
console.log(`typecheck-specs: ${specs.length} specs, ${name} -p ${configName}`)
const run = spawnSync(process.execPath, [checker, '--noEmit', '-p', configName], {
  cwd: root,
  stdio: 'inherit',
})
process.exit(run.status ?? 1)
