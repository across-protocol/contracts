#!/bin/bash

CONTRACTS=("Arbitrum_SpokePool" "Optimism_SpokePool" "Polygon_SpokePool" "Linea_SpokePool" "ZkSync_SpokePool" "Ethereum_SpokePool" "Base_SpokePool" "Mode_SpokePool")
if [[ "$1" == "--overwrite" ]]; then
    for CONTRACT in "${CONTRACTS[@]}"; do
        echo "Overwrite flag detected. Creating new storage layout snapshot of the $CONTRACT contract"
        forge inspect $CONTRACT storagelayout > ./storage-layouts/temp.$CONTRACT.json
        # Delete any astId keys from the file, which seem to change every time the bytecode changes
        # and the types object which also contains astId changes. We only care about the size and relative
        # location of state variable slots.
        jq 'del(.storage[] | .astId)' ./storage-layouts/temp.$CONTRACT.json | jq 'del(.storage[] | .type)' | jq 'del(.types)' > ./storage-layouts/$CONTRACT.json
        rm ./storage-layouts/temp.$CONTRACT.json
        echo "✅ 'forge inspect' saved new $CONTRACT storage layout at './storage-layouts/$CONTRACT.json'."
    done
    exit 0
fi

for CONTRACT in "${CONTRACTS[@]}"; do
    echo "Comparing storage layout snapshot of the $CONTRACT contract at ./storage-layouts/$CONTRACT.json with current storage layout"
    echo "Created temporary storage layout file at ./storage-layouts/proposed.$CONTRACT.json"
    forge inspect $CONTRACT storagelayout > ./storage-layouts/proposed.$CONTRACT.json
    echo "'forge inspect' command created temp storage layout file!"
    if ! diff -q "./storage-layouts/proposed.$CONTRACT.json" "./storage-layouts/$CONTRACT.json" &>/dev/null; then
        >&2 echo "❌ Diff detected in storage layout for $CONTRACT. Please update the storage layout file in the storage-layouts/ directory."
        echo "You can generate a new storage layout file by running this script with the '--overwrite' flag"
        exit 1
    fi
    echo "✅ No diff detected, deleting ./storage-layouts/proposed.$CONTRACT.json"
    rm ./storage-layouts/proposed.$CONTRACT.json
done

exit 0

