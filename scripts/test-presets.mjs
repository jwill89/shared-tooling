/**
 * Loads every config and preset projects import from here, each from its own folder's
 * install (lint/web's and test/a11y's node_modules), and fails when one doesn't load or
 * exports nothing. What `task presets` and CI's web job run.
 */

/** The Vitest preset with CI_CPUS set to `cpus` (or unset), as a CI job would read it. */
function vitestWith(m, cpus) {
  const saved = process.env.CI_CPUS
  if (cpus === undefined) {
    delete process.env.CI_CPUS
  } else {
    process.env.CI_CPUS = cpus
  }
  try {
    return m.vitestDefaults({ floor: { lines: 1 } })
  } finally {
    if (saved === undefined) {
      delete process.env.CI_CPUS
    } else {
      process.env.CI_CPUS = saved
    }
  }
}

/** Whether an ESLint config's spec overrides hold the shared wait rule. */
function specsWait(m) {
  const rule = m.specWaitRules?.['no-restricted-syntax']
  return Boolean(rule) && m.default.some((c) => c.rules?.['no-restricted-syntax'] === rule)
}

const checks = [
  ['lint/web/eslint.js', (m) => Array.isArray(m.default) && m.vueConventions && m.tsStylistic && specsWait(m)],
  ['lint/web/eslint-react.js', (m) => Array.isArray(m.default) && specsWait(m)],
  ['lint/web/eslint-js.js', (m) => Array.isArray(m.default) && Array.isArray(m.tseslint?.configs?.recommendedTypeChecked)],
  ['lint/web/prettier.js', (m) => m.default?.singleQuote === true],
  ['lint/web/stylelint.js', (m) => m.default && typeof m.paletteRules === 'function'],
  ['lint/web/stylelint-tailwind.js', (m) => Boolean(m.default)],
  ['test/a11y/index.js', (m) => typeof m.axeViolations === 'function' && m.WCAG_22_AA.length > 0],
  [
    'test/web/vitest.js',
    // The floor; expect.poll's wait; one worker for each CPU a job is told it has but one,
    // at least one; and Vitest's own count when CI_CPUS is unset or not a whole number.
    (m) =>
      vitestWith(m).coverage.thresholds.lines === 1 &&
      vitestWith(m).expect.poll.timeout === m.waitTimeout &&
      m.waitTimeout >= 5000 &&
      vitestWith(m, '3').maxWorkers === 2 &&
      vitestWith(m, '1').maxWorkers === 1 &&
      !('maxWorkers' in vitestWith(m)) &&
      !('maxWorkers' in vitestWith(m, '0')) &&
      !('maxWorkers' in vitestWith(m, '2.5')) &&
      !('maxWorkers' in vitestWith(m, 'two')),
  ],
  ['test/e2e/playwright.js', (m) => m.playwrightDefaults.testDir === 'e2e'],
]

let failed = 0
for (const [file, valid] of checks) {
  try {
    const loaded = await import(new URL(`../${file}`, import.meta.url).href)
    if (!valid(loaded)) {
      throw new Error('it loads but exports something else')
    }
    console.log(`ok    ${file}`)
  } catch (error) {
    failed++
    console.error(`FAIL  ${file}: ${error instanceof Error ? error.message : String(error)}`)
  }
}
process.exit(failed ? 1 : 0)
