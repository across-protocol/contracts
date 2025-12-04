#!/bin/sh

# This script runs pretty-quick and rustfmt on staged files before committing. It is intended to be used as a pre-commit
# hook. We want to run pretty-quick first, so that it handles formatting of macro lines in rust code, but we use rustfmt
# on top of it to use standard rust formatting for the rest of the rust code.

# Store staged rust files for later use in rustfmt as pretty-quick might revert some changes
STAGED_RUST_FILES=$(git diff --cached --name-only --diff-filter=d | grep '\.rs$')

echo "Running pretty-quick on staged files ..."

yarn pretty-quick --staged
PRETTY_QUICK_EXIT=$?
if [ $PRETTY_QUICK_EXIT -ne 0 ]; then
    echo "pretty-quick encountered an error. Aborting the hook."
    exit $PRETTY_QUICK_EXIT
fi

echo "Running rustfmt on staged files ..."

if [ -n "$STAGED_RUST_FILES" ]; then
    echo "$STAGED_RUST_FILES" | xargs -I {} rustfmt +nightly {}
    RUSTFMT_EXIT=$?
    if [ $RUSTFMT_EXIT -ne 0 ]; then
        echo "rustfmt encountered an error. Aborting the hook."
        exit $RUSTFMT_EXIT
    fi

    # Restage any formatted rust files
    echo "$STAGED_RUST_FILES" | xargs git add
fi

echo "Running generate-constants-json on staged files ..."
yarn generate-constants-json && yarn prettier --write generated/constants.json
if git diff --name-only | grep -E 'generated/constants.json$' >/dev/null; then
    echo "Generated constants have changed."
    git add generated/constants.json
fi
GENERATE_CONSTANTS_JSON_EXIT=$?
if [ $GENERATE_CONSTANTS_JSON_EXIT -ne 0 ]; then
    echo "generate-constants-json encountered an error. Aborting the hook."
    exit $GENERATE_CONSTANTS_JSON_EXIT
fi

echo "Running extract-addresses on staged files ..."
yarn extract-addresses && yarn prettier --write broadcast/deployed-addresses.json && yarn prettier --write broadcast/deployed-addresses.md
EXTRACT_ADDRESSES_EXIT=$?
if [ $EXTRACT_ADDRESSES_EXIT -ne 0 ]; then
    echo "extract-addresses encountered an error. Aborting the hook."
    exit $EXTRACT_ADDRESSES_EXIT
fi
if git diff --name-only | grep -E 'broadcast/deployed-addresses\.(json|md)$' >/dev/null; then
    echo "Broadcast or deployed addresses have changed."
    git add broadcast/deployed-addresses.json
    git add broadcast/deployed-addresses.md
fi
