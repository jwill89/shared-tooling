/**
 * Tailwind CSS 4's at-rules and conventions, on top of the shared Stylelint config:
 *
 *   export default {
 *     extends: ['@jwill89/lint-web/stylelint', '@jwill89/lint-web/stylelint/tailwind'],
 *   }
 */
export default {
  rules: {
    'at-rule-no-unknown': [
      true,
      {
        ignoreAtRules: [
          'theme',
          'utility',
          'custom-variant',
          'variant',
          'apply',
          'reference',
          'source',
          'plugin',
          'config',
        ],
      },
    ],
    // Tailwind imports by name, not by url().
    'import-notation': 'string',
    // `--color-*: initial` is how Tailwind clears a namespace of its defaults.
    'custom-property-pattern': [
      '^[a-z][a-z0-9]*(-[a-z0-9]+)*(-\\*)?$',
      { message: 'Name custom properties in kebab-case' },
    ],
  },
}
