import js from '@eslint/js';

export default [
  js.configs.recommended,
  {
    ignores: ['coverage/**', 'bin/**', 'obj/**']
  },
  {
    languageOptions: {
      ecmaVersion: 2020,
      sourceType: 'script'
    }
  }
];
