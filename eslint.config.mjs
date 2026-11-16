import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import prettierConfig from "eslint-config-prettier/flat";
import chaiExpect from "eslint-plugin-chai-expect";
import mocha from "eslint-plugin-mocha";
import n from "eslint-plugin-n";
import tseslint from "typescript-eslint";

// Follows @across-protocol/sdk/eslint, which can't be imported here because the sdk depends on this package.
export default defineConfig(
  { ignores: ["dist/", "lib/", "target/", "src/svm/clients/", "eslint.config.mjs"] },
  js.configs.recommended,
  tseslint.configs.recommended,
  n.configs["flat/recommended"],
  prettierConfig, // Formatting is checked by prettier itself.
  {
    linterOptions: { reportUnusedDisableDirectives: "error" },
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      parserOptions: {
        project: "./tsconfig.eslint.json",
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: { "chai-expect": chaiExpect, mocha },
    settings: { node: { tryExtensions: [".js", ".ts"] } },
    rules: {
      "linebreak-style": ["error", "unix"],
      quotes: ["error", "double", { avoidEscape: true }],
      semi: ["error", "always"],
      "spaced-comment": ["error", "always", { exceptions: ["-", "+"] }],
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
          destructuredArrayIgnorePattern: "^_",
          ignoreRestSiblings: true,
        },
      ],
      "chai-expect/missing-assertion": 2,
      "mocha/no-exclusive-tests": "error",
      "no-inner-declarations": ["error", "functions", { blockScopedFunctions: "disallow" }],
      "no-duplicate-imports": "error",
      "@typescript-eslint/return-await": ["error", "error-handling-correctness-only"],
      "@typescript-eslint/only-throw-error": ["error"],
      "@typescript-eslint/require-array-sort-compare": ["error"],
      "@typescript-eslint/no-unnecessary-type-assertion": ["error"],
      "@typescript-eslint/no-redundant-type-constituents": ["error"],
      "array-callback-return": "error",
      eqeqeq: ["error", "smart"],
      "no-console": "error",
      "@typescript-eslint/no-require-imports": "off",
      "n/hashbang": "off", // Scripts are run via ts-node, not as package bins.
      "n/no-missing-import": "off", // TypeScript handles import resolution
      "n/no-process-exit": "off",
      "prefer-const": ["error", { destructuring: "all" }],
      "n/no-unsupported-features/es-syntax": ["error", { ignores: ["modules"] }],
      // Follow-up: enabled in the sdk and relayer; existing violations not yet fixed.
      "@typescript-eslint/no-explicit-any": "off", // 177 sites
      "@typescript-eslint/no-floating-promises": "off", // 45 sites, mostly unhandled main() in scripts/
      "@typescript-eslint/await-thenable": "off", // 20 sites
      "@typescript-eslint/no-misused-promises": "off", // 5 sites
      "require-await": "off", // 15 sites
      "preserve-caught-error": "off", // 4 sites
    },
  },
  {
    files: ["scripts/**", "script/**", "test/**"],
    rules: {
      "no-console": "off",
    },
  },
  {
    files: ["test/**/*.ts"],
    rules: {
      "@typescript-eslint/no-unused-expressions": "off", // Chai assertions are "unused expressions"
    },
  }
);
