module.exports = {
  env: {
    browser: false,
    es2021: true,
    mocha: true,
    node: true,
  },
  plugins: ["@typescript-eslint"],
  extends: ["standard", "plugin:prettier/recommended", "plugin:node/recommended", "plugin:mocha/recommended"],
  parser: "@typescript-eslint/parser",
  parserOptions: {
    ecmaVersion: 12,
  },
  rules: {
    "node/no-unsupported-features/es-syntax": ["error", { ignores: ["modules"] }],
    "node/no-missing-import": [
      "error",
      {
        tryExtensions: [".js", ".ts"],
        resolvePaths: ["."],
      },
    ],
    "mocha/no-exclusive-tests": "error",
    "@typescript-eslint/no-var-requires": 0,
  },
};
