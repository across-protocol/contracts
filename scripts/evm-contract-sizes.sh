#!/bin/bash

# Read the current optimizer runs value from foundry.toml
DEFAULT_RUNS=$(grep "optimizer_runs" foundry.toml | awk '{print $3}')

# Prompt for optimizer runs
read -p "Enter number of optimizer runs (press enter to use $DEFAULT_RUNS): " OPTIMIZER_RUNS

# If no input provided, use the default value
if [ -z "$OPTIMIZER_RUNS" ]; then
    OPTIMIZER_RUNS=$DEFAULT_RUNS
fi

# Run forge build with specified optimizer runs
forge build --sizes --skip test --optimizer-runs $OPTIMIZER_RUNS

exit 0