// Takes in-range npm updates for Invoke-DependencyCheck.ps1 -Update, so `npm install` can resolve
// them: each package's range in package.json rises to the new version, keeping its ^, ~ or exact
// form, and the lockfile forgets the package's family, with that part of node_modules.
//
// A family is the package and the packages of its scope tied to it by an exact version, either
// way and through each other. Tiptap's packages pin each other exactly through peer dependencies,
// so all of @tiptap/ moves together (`npm update` moved only some of them and left two copies of
// @tiptap/core). The @types/ packages name each other by range and are released one by one, so
// @types/node moves alone. The family stays that narrow because npm install doesn't always
// resolve a dropped entry again when only a package it kept needs it: dropping all of @types/
// lost @eslint/core's @types/json-schema from the lockfile, and npm ci then refused it.
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

const lockPath = join(dir, 'package-lock.json')
const lock = JSON.parse(readFileSync(lockPath, 'utf8'))
const marker = 'node_modules/'
const nameOf = (key) => key.slice(key.lastIndexOf(marker) + marker.length)
const scopeOf = (name) => (name.startsWith('@') ? name.split('/')[0] : '')
// A range that names one version, as the members of a family name each other.
const isExact = (range) =>
  typeof range === 'string' && /^=?v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$/.test(range.trim())

// The installed packages, every copy of each, and for each name the scope-mates it is tied to by
// an exact version, whichever of the two names the other.
const keys = Object.keys(lock.packages).filter((key) => key.includes(marker))
const ties = new Map()
const tie = (from, to) => {
  if (!ties.has(from)) ties.set(from, new Set())
  ties.get(from).add(to)
}
for (const key of keys) {
  const name = nameOf(key)
  const scope = scopeOf(name)
  if (!scope) continue
  for (const section of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const [dep, range] of Object.entries(lock.packages[key][section] ?? {})) {
      if (scopeOf(dep) !== scope || !isExact(range)) continue
      tie(name, dep)
      tie(dep, name)
    }
  }
}

const family = new Set(updates.map(({ name }) => name))
const queue = [...family]
while (queue.length) {
  for (const next of ties.get(queue.pop()) ?? []) {
    if (family.has(next)) continue
    family.add(next)
    queue.push(next)
  }
}

const dropped = keys.filter((key) => family.has(nameOf(key)))
for (const key of dropped) {
  delete lock.packages[key]
  rmSync(join(dir, key), { recursive: true, force: true })
}
writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
const names = [...new Set(dropped.map(nameOf))].sort()
console.log(
  `${dir}: ${updates.length} range(s) raised; lockfile entries for ${names.join(', ') || 'nothing'} dropped`,
)
