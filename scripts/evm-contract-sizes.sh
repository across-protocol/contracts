#!/bin/bash

# Read the current optimizer runs value from foundry.toml
DEFAULT_RUNS=$(grep "optimizer_runs" foundry.toml | awk '{print $3}')

# Prompt for optimizer runs
read -p "Enter number of optimizer runs (press enter to use $DEFAULT_RUNS): " OPTIMIZER_RUNS

# If no input provided, use the default value
if [ -z "$OPTIMIZER_RUNS" ]; then
    OPTIMIZER_RUNS=$DEFAULT_RUNS
fi

# Backup the original foundry.toml
cp foundry.toml foundry.toml.bak

# Function to restore the original file
restore_config() {
    mv foundry.toml.bak foundry.toml
}

# Set up trap to restore file on script exit (success or failure)
trap restore_config EXIT

# Modify the optimizer runs in foundry.toml
sed -i '' "s/optimizer_runs = .*/optimizer_runs = $OPTIMIZER_RUNS/" foundry.toml

# Run forge build
forge build --sizes --skip test

# Always exit with success
exit 0