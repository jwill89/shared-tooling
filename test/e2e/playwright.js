/**
 * The shared Playwright settings, seeded from TarotGen.io's and Home Library's: tests
 * in e2e/, one worker in order (the steps share one server and one database), a trace
 * kept when a test fails, and the browser already on the machine. Locally on Windows
 * that is Edge, so nothing is downloaded; CI uses the runner's Chrome.
 *
 *   // playwright.config.ts
 *   import { defineConfig } from '@playwright/test'
 *   import { playwrightDefaults } from '../shared/test/e2e/playwright.js'
 *   export default defineConfig({
 *     ...playwrightDefaults,
 *     use: { ...playwrightDefaults.use, baseURL: 'http://127.0.0.1:8140' },
 *     webServer: { command: '...', url: 'http://127.0.0.1:8140/api/health' },
 *   })
 */
const ci = Boolean(process.env.CI)

export const playwrightDefaults = {
  testDir: 'e2e',
  workers: 1,
  fullyParallel: false,
  forbidOnly: ci,
  retries: ci ? 1 : 0,
  reporter: ci ? [['github'], ['list']] : 'list',
  outputDir: 'test-results',
  use: {
    trace: 'retain-on-failure',
    channel: ci ? 'chrome' : process.platform === 'win32' ? 'msedge' : 'chrome',
  },
}
