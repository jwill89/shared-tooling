// The settings as plain types, with no import: this file sits in shared/, outside the
// front end's folder, where @playwright/test cannot be resolved. The project's own
// defineConfig() checks them against its own @playwright/test when it spreads them.
export declare const playwrightDefaults: {
  testDir: string
  workers: number
  fullyParallel: boolean
  forbidOnly: boolean
  retries: number
  reporter: 'list' | (['github'] | ['list'])[]
  outputDir: string
  use: {
    trace: 'retain-on-failure'
    channel: string
  }
}
