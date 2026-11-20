/**
 * How long a test waits for what the app does in its own time, in milliseconds: soon()'s
 * timeout (wait.js) and expect.poll's. A wait passes as soon as what it checks holds, so
 * the budget costs a passing test nothing, and it covers a CI job whose thread gets far
 * less of a CPU than a desk's, where Vitest's own 1 s has failed tests that take
 * milliseconds locally.
 */
export const waitTimeout = 5_000

/**
 * The CPUs this run may use, from CI_CPUS, which a job on the self-hosted runners is
 * given (runner/README.md) and `task shared:ci:share` sets; undefined when it isn't a
 * whole number above 0.
 *
 * @returns {number | undefined}
 */
function ciCpus() {
  const cpus = Number(process.env.CI_CPUS)
  return Number.isInteger(cpus) && cpus > 0 ? cpus : undefined
}

/**
 * The shared Vitest settings: jsdom for tests that need a DOM, mocks and stubbed
 * globals put back after each test, v8 coverage over all of src with a floor that only
 * rises, workers for the CPUs a CI job has, and waitTimeout for expect.poll.
 *
 *   // vite.config.ts
 *   import { vitestDefaults } from '../shared/test/web/vitest.js'
 *   export default defineConfig({
 *     test: vitestDefaults({
 *       include: ['src/**\/*.spec.ts'],
 *       floor: { statements: 96, branches: 92, functions: 95, lines: 97 },
 *     }),
 *   })
 *
 * A suite with no DOM passes `environment: 'node'`.
 * The floor starts a little under what the suite reaches today; raise it as tests
 * land, never lower it.
 *
 * @param {import('./vitest.d.ts').VitestDefaultsOptions} options
 */
export function vitestDefaults({
  environment = 'jsdom',
  include = ['src/**/*.{test,spec}.ts'],
  setupFiles = [],
  floor,
  coverageExclude = [],
} = {}) {
  const cpus = ciCpus()
  return {
    environment,
    include,
    setupFiles,
    // 15 s, not Vitest's 5: `task check` runs the tests beside lint and the scans, and a
    // file's first test imports the app cold, which under that load can take longer than
    // 5 s. A test that hangs still fails, later.
    testTimeout: 15_000,
    // A job on the self-hosted runners sees the processors every running job shares, not
    // its own share of them, which it is told in CI_CPUS. Vitest starts a worker for each
    // processor it sees but one, which the main thread keeps; so here for each CPU of the
    // share but one.
    ...(cpus ? { maxWorkers: Math.max(1, cpus - 1) } : {}),
    // expect.poll waits waitTimeout by default, as soon() does, rather than Vitest's 1 s.
    expect: { poll: { timeout: waitTimeout } },
    restoreMocks: true,
    unstubGlobals: true,
    coverage: {
      provider: 'v8',
      // Measured over all of src, untested files included, so the numbers say how
      // much of the app the tests reach. Generated code and type-only files are left
      // out of the count.
      include: ['src/**/*.{ts,vue,tsx}'],
      exclude: [
        'src/**/*.d.ts',
        'src/**/__tests__/**',
        'src/**/*.{test,spec}.{ts,tsx}',
        'src/types/api.generated.ts',
        'src/api/schema.d.ts',
        ...coverageExclude,
      ],
      reporter: ['text-summary', 'html'],
      ...(floor ? { thresholds: floor } : {}),
    },
  }
}
