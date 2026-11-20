/**
 * Rules for specs that eslint.js and eslint-react.js both set in their test overrides.
 *
 * A wait on the clock at vi.waitFor's or vi.waitUntil's own 1 s fails on a busy CI
 * runner while it passes at a desk, so each names its timeout or goes through soon()
 * (test/web/wait.js), whose budget suits CI. expect.poll needs neither: the shared Vitest
 * preset sets its default. A project that sets no-restricted-syntax for its specs
 * replaces this rule, so it copies these entries into its own.
 */
export const specWaitRules = {
  'no-restricted-syntax': [
    'error',
    {
      selector:
        "CallExpression[callee.object.name='vi'][callee.property.name=/^(waitFor|waitUntil)$/][arguments.length<2]",
      message:
        "vi.waitFor's and vi.waitUntil's 1 s fails on a busy CI runner: wait with soon() from shared/test/web/wait.js, or pass a timeout.",
    },
  ],
}
