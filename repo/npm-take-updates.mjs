// Takes in-range npm updates for Invoke-DependencyCheck.ps1 -Update, so `npm install` can resolve
// them: each package's range in package.json rises to the new version, keeping its ^, ~ or exact
// form, and the lockfile forgets the package's whole family (its scope, such as @tiptap/, or the
// package alone), with that part of node_modules. A family whose members pin each other exactly
// through peer dependencies, as Tiptap's do, then moves together; `npm update` moved only some of
// Tiptap's packages and left two copies of @tiptap/core.
//
//   node npm-take-updates.mjs <folder> <name>@<version> ...
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [dir, ...specs] = process.argv.slice(2)
const updates = specs.map((spec) => {
  const at = spec.lastIndexOf('@')
  return { name: spec.slice(0, at), version: spec.slice(at + 1) }
})

const pkgPath = join(dir, 'package.json')
const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
for (const { name, version } of updates) {
  for (const section of ['dependencies', 'devDependencies', 'optionalDependencies']) {
    const range = pkg[section]?.[name]
    if (range === undefined) continue
    const prefix = /^[\^~]/.exec(range)?.[0] ?? ''
    pkg[section][name] = `${prefix}${version}`
  }
}
writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`)

const families = [...new Set(updates.map(({ name }) => (name.startsWith('@') ? `${name.split('/')[0]}/` : name)))]
const inFamily = (key) =>
  families.some((family) => {
    const tail = key.slice(key.lastIndexOf('node_modules/') + 'node_modules/'.length)
    return family.endsWith('/') ? tail.startsWith(family) : tail === family
  })
const lockPath = join(dir, 'package-lock.json')
const lock = JSON.parse(readFileSync(lockPath, 'utf8'))
for (const key of Object.keys(lock.packages)) {
  if (key && inFamily(key)) delete lock.packages[key]
}
writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
for (const family of families) {
  rmSync(join(dir, 'node_modules', family), { recursive: true, force: true })
}
console.log(`${dir}: ${updates.length} range(s) raised; lockfile entries for ${families.join(', ')} dropped`)
