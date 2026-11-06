import js from '@eslint/js'
import configPrettier from 'eslint-config-prettier'
import jsxA11y from 'eslint-plugin-jsx-a11y-x'
import reactHooks from 'eslint-plugin-react-hooks'
import globals from 'globals'
import tseslint from 'typescript-eslint'

/**
 * Shared ESLint flat config for jwill89 React + TypeScript front ends (Family Card
 * Game). The same curated rules as the Vue config, on typescript-eslint's
 * strictTypeChecked, React's hooks rules and JSX accessibility.
 *
 *   import shared from '@jwill89/lint-web/react'
 *   export default [{ ignores: ['dist/**'] }, ...shared]
 *
 * The accessibility rules come from eslint-plugin-jsx-a11y-x, the eslint-community
 * fork of eslint-plugin-jsx-a11y: the original supports ESLint up to 9. Its rules are
 * named `jsx-a11y-x/…`.
 */
export default tseslint.config(
  {
    name: 'jwill-react/files',
    files: ['**/*.{ts,mts,tsx}'],
    extends: [js.configs.recommended, ...tseslint.configs.strictTypeChecked],
    languageOptions: {
      globals: globals.browser,
      parserOptions: { projectService: true },
    },
  },

  {
    name: 'jwill-react/hooks',
    files: ['**/*.{ts,mts,tsx}'],
    ...reactHooks.configs.flat['recommended-latest'],
  },

  // JSX accessibility: labels, alt text, interactive roles (WCAG 2.2 AA).
  {
    ...jsxA11y.configs.recommended,
    name: 'jwill-react/a11y',
    files: ['**/*.{ts,mts,tsx}'],
  },

  {
    name: 'jwill-react/rules',
    files: ['**/*.{ts,mts,tsx}'],
    rules: {
      'prefer-const': 'error',
      'no-param-reassign': ['error', { props: false }],
      eqeqeq: ['error', 'smart'],
      curly: ['error', 'all'],
      'object-shorthand': 'error',
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],
      '@typescript-eslint/naming-convention': [
        'error',
        { selector: 'typeLike', format: ['PascalCase'] },
        { selector: 'enumMember', format: ['PascalCase'] },
      ],
      '@typescript-eslint/restrict-template-expressions': [
        'error',
        { allowNumber: true, allowBoolean: true },
      ],
      // `onClick={() => setOpen(false)}` is idiomatic React.
      '@typescript-eslint/no-confusing-void-expression': ['error', { ignoreArrowShorthand: true }],
    },
  },

  {
    name: 'jwill-react/test-overrides',
    files: ['**/*.{test,spec}.{ts,tsx}', '**/__tests__/**'],
    rules: {
      '@typescript-eslint/no-non-null-assertion': 'off',
      '@typescript-eslint/require-await': 'off',
      '@typescript-eslint/no-floating-promises': 'off',
      '@typescript-eslint/unbound-method': 'off',
    },
  },

  // Turns off the rules that would fight Prettier.
  configPrettier,

  // After it: eslint-config-prettier turns `curly` off, though `all` is safe beside
  // Prettier (only its multi-line options conflict).
  { name: 'jwill-react/after-prettier', rules: { curly: ['error', 'all'] } },
)
