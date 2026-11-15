/**
 * Type-checks a front end's Vitest specs under their own tsconfig.vitest.json, the check
 * web.yml runs after the app's scripts:
 *
 *   node ../shared/test/web/typecheck-specs.mjs [front-end folder] [--fix]
 *
 * An app with Vitest specs (vitest in its package.json and a *.spec or *.test file under
 * src/) needs a tsconfig.vitest.json that extends @jwill89/lint-web/tsconfig.vitest.json
 * and takes in every spec. Its specs are then checked with vue-tsc where the app has it,
 * else with tsc, both from the app's own install. An app with no Vitest, or no specs yet,
 * passes with a note.
 *
 * --fix writes the file where it is missing, extending the app's own config
 * (tsconfig.app.json, or tsconfig.json where that is the only one) and then the base, or
 * adds the base to the extends of one that lacks it, then checks that every spec is taken
 * in. It runs no type-check, and names whatever it can't put right itself.
 */
import { spawnSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'

const base = '@jwill89/lint-web/tsconfig.vitest.json'
const configName = 'tsconfig.vitest.json'

const fail = (message) => {
  console.error(`typecheck-specs: ${message}`)
  process.exit(1)
}

const args = process.argv.slice(2)
const fix = args.includes('--fix')
const root = path.resolve(args.find((arg) => !arg.startsWith('--')) ?? '.')
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

// The specs, and which kinds of source sit beside them, for the include a new file gets.
const specs = []
const kinds = new Set()
const walk = (folder) => {
  for (const entry of readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name)
    if (entry.isDirectory()) {
      if (entry.name !== 'node_modules') {
        walk(full)
      }
    } else {
      if (/\.(spec|test)\.(ts|tsx|mts)$/.test(entry.name)) {
        specs.push(full)
      }
      const kind = /\.(tsx|vue)$/.exec(entry.name)
      if (kind) {
        kinds.add(kind[1])
      }
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

// The app's own config the specs' file extends first, and the extends line that names it.
const appConfig = ['tsconfig.app.json', 'tsconfig.json'].find((name) => existsSync(path.join(root, name)))
const wantedExtends = appConfig ? [`./${appConfig}`, base] : [base]
// One line per array, as Prettier writes a short one.
const inline = (value) => JSON.stringify(value).replaceAll('","', '", "')
const extendsLine = `"extends": ${inline(wantedExtends)}`
const include = ['src/**/*.ts', ...(kinds.has('tsx') ? ['src/**/*.tsx'] : []), ...(kinds.has('vue') ? ['src/**/*.vue'] : [])]

const configPath = path.join(root, configName)
if (!existsSync(configPath)) {
  if (!fix) {
    fail(`the app has Vitest specs but no ${configName}. Add one with ${extendsLine}, or run task shared:web:specs -- --fix.`)
  }
  if (!appConfig) {
    fail(`the app has no tsconfig.app.json or tsconfig.json for ${configName} to extend; add the app's config first.`)
  }
  writeFileSync(configPath, `{\n  ${extendsLine},\n  "include": ${inline(include)}\n}\n`)
  console.log(`typecheck-specs: wrote ${configName}, extending ./${appConfig} and then the shared base.`)
}

// The app's own TypeScript reads the config, comments and all, as tsc would.
const require = createRequire(manifestPath)
let ts
try {
  ts = require('typescript')
} catch {
  fail('TypeScript is not installed in the app; run npm ci first.')
}
const readConfig = () => {
  const read = ts.readConfigFile(configPath, ts.sys.readFile)
  if (read.error) {
    fail(ts.flattenDiagnosticMessageText(read.error.messageText, '\n'))
  }
  return read.config
}
let config = readConfig()
let extended = [config.extends ?? []].flat()
if (!extended.includes(base)) {
  const advice = `${configName} must extend ${base} (it extends ${JSON.stringify(config.extends ?? null)}). Make its extends: ${extendsLine}`
  if (!fix) {
    fail(`${advice}, or run task shared:web:specs -- --fix.`)
  }
  // The extends value is replaced in the text, so the rest of the file, comments and all,
  // stays as it was. A file with no extends, or one written so it can't be found, is left
  // for the owner, with the line to add.
  const text = readFileSync(configPath, 'utf8')
  const found = [...text.matchAll(/("extends"\s*:\s*)("(?:[^"\\]|\\.)*"|\[[^\]]*\])/g)]
  if (found.length !== 1) {
    fail(`${advice}; ${found.length ? 'it names extends more than once' : 'it has no extends'}, so it was left as it is.`)
  }
  const [match, key] = found[0]
  const updated = text.slice(0, found[0].index) + key + inline([...extended, base]) + text.slice(found[0].index + match.length)
  writeFileSync(configPath, updated)
  config = readConfig()
  extended = [config.extends ?? []].flat()
  if (!extended.includes(base)) {
    writeFileSync(configPath, text)
    fail(`${advice}; the change didn't take, so the file was put back as it was.`)
  }
  console.log(`typecheck-specs: ${configName} now extends ${inline(extended)}.`)
}

const parsed = ts.parseJsonConfigFileContent(config, ts.sys, root, undefined, configPath)
const included = new Set(parsed.fileNames.map((file) => path.resolve(file)))
const missing = specs.filter((spec) => !included.has(path.resolve(spec)))
if (missing.length > 0) {
  const list = missing.map((spec) => `  ${path.relative(root, spec)}`).join('\n')
  fail(`${configName} leaves out these specs, so nothing type-checks them:\n${list}\nIts include should take them in, such as "include": ${inline(include)}.`)
}
if (fix) {
  console.log(`typecheck-specs: ${configName} extends the shared base and takes in all ${specs.length} specs.`)
  process.exit(0)
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
