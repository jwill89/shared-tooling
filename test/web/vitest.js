/**
 * The shared Vitest settings, seeded from the Gallery's and TarotGen.io's: jsdom for
 * tests that need a DOM (decided 2026-11-05), mocks and stubbed globals put back after
 * each test, and v8 coverage over all of src with a floor that only rises.
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
 * A suite with no DOM (Fantasy Dossier's) passes `environment: 'node'`.
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
  return {
    environment,
    include,
    setupFiles,
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
