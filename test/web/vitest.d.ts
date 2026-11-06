export interface CoverageFloor {
  statements?: number
  branches?: number
  functions?: number
  lines?: number
}

export interface VitestDefaultsOptions {
  /** 'jsdom' (the default) for tests that need a DOM, 'node' for those that don't. */
  environment?: 'jsdom' | 'node'
  include?: string[]
  setupFiles?: string[]
  /** The coverage floor; `vitest run --coverage` fails below it. */
  floor?: CoverageFloor
  /** More files to leave out of the coverage count (generated code, startup wiring). */
  coverageExclude?: string[]
}

export declare function vitestDefaults(options?: VitestDefaultsOptions): {
  environment: 'jsdom' | 'node'
  include: string[]
  setupFiles: string[]
  restoreMocks: true
  unstubGlobals: true
  coverage: {
    provider: 'v8'
    include: string[]
    exclude: string[]
    reporter: string[]
    thresholds?: CoverageFloor
  }
}
