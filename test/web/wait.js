/**
 * soon(): waits for what the app does in its own time (a list opening, a request answered,
 * a route followed) with the budget a CI job needs, in place of vi.waitFor's 1 s.
 *
 *   import { soon } from '../../../shared/test/web/wait.js'
 *   const option = await soon(() => screen.getByRole('option', { name: 'Red' }))
 *
 * Vitest resolves the import of `vitest` here from the project, so a spec imports this file
 * by path like the preset, never installs it.
 */
import { vi } from 'vitest'

import { waitTimeout } from './vitest.js'

/**
 * Calls `check` until it returns, or resolves, without throwing, and gives back what it
 * returned; throws its last error once `timeout` passes. vi.waitFor with waitTimeout
 * (five seconds) as its timeout, so it also moves fake timers on as it waits.
 *
 * @template T
 * @param {() => T | Promise<T>} check
 * @param {import('./wait.d.ts').SoonOptions} [options]
 * @returns {Promise<T>}
 */
export function soon(check, { timeout = waitTimeout, interval = 50 } = {}) {
  return vi.waitFor(check, { timeout, interval })
}
