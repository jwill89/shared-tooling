import js from '@eslint/js'
import configPrettier from 'eslint-config-prettier'
import globals from 'globals'

/**
 * Shared ESLint flat config for plain JavaScript: a static site's own scripts, with no
 * Vue, React or TypeScript. ESLint's recommended rules and the curated rules the other
 * configs share, in the browser; config files at the root run in Node.
 *
 *   // eslint.config.js
 *   import shared from '@jwill89/lint-web/js'
 *   export default [{ ignores: ['dist/**', 'vendor/**'] }, ...shared]
 *
 * Every file is read as an ES module. A classic script, whose top-level functions a page
 * calls from its markup, is listed by the project with `sourceType: 'script'`.
 */
export default [
  {
    ...js.configs.recommended,
    name: 'jwill-js/recommended',
    files: ['**/*.{js,mjs,cjs}'],
    languageOptions: { globals: globals.browser },
  },

  {
    name: 'jwill-js/node-configs',
    files: ['*.config.{js,mjs,cjs}', 'eslint.config.{js,mjs,cjs}'],
    languageOptions: { globals: globals.node },
  },

  {
    name: 'jwill-js/rules',
    files: ['**/*.{js,mjs,cjs}'],
    rules: {
      'prefer-const': 'error',
      'no-param-reassign': ['error', { props: false }],
      eqeqeq: ['error', 'smart'],
      curly: ['error', 'all'],
      'object-shorthand': 'error',
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      'no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],
    },
  },

  // Turns off the rules that would fight Prettier.
  configPrettier,

  // After it: eslint-config-prettier turns `curly` off, though `all` is safe beside
  // Prettier (only its multi-line options conflict).
  { name: 'jwill-js/after-prettier', rules: { curly: ['error', 'all'] } },
]
