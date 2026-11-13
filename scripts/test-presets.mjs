/**
 * Loads every config and preset projects import from here, each from its own folder's
 * install (lint/web's and test/a11y's node_modules), and fails when one doesn't load or
 * exports nothing. What `task presets` and CI's web job run.
 */
const checks = [
  ['lint/web/eslint.js', (m) => Array.isArray(m.default) && m.vueConventions && m.tsStylistic],
  ['lint/web/eslint-react.js', (m) => Array.isArray(m.default)],
  ['lint/web/eslint-js.js', (m) => Array.isArray(m.default)],
  ['lint/web/prettier.js', (m) => m.default?.singleQuote === true],
  ['lint/web/stylelint.js', (m) => m.default && typeof m.paletteRules === 'function'],
  ['lint/web/stylelint-tailwind.js', (m) => Boolean(m.default)],
  ['test/a11y/index.js', (m) => typeof m.axeViolations === 'function' && m.WCAG_22_AA.length > 0],
  ['test/web/vitest.js', (m) => m.vitestDefaults({ floor: { lines: 1 } }).coverage.thresholds.lines === 1],
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
