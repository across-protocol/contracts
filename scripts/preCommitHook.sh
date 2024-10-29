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
    echo "$STAGED_RUST_FILES" | xargs -I {} rustfmt --edition 2021 {}
    RUSTFMT_EXIT=$?
    if [ $RUSTFMT_EXIT -ne 0 ]; then
        echo "rustfmt encountered an error. Aborting the hook."
        exit $RUSTFMT_EXIT
    fi

    # Restage any formatted rust files
    echo "$STAGED_RUST_FILES" | xargs git add
fi
