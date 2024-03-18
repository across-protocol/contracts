#!/bin/bash

CONTRACTS=("Arbitrum_SpokePool" "Optimism_SpokePool" "Polygon_SpokePool", "Linea_SpokePool", "ZkSync_SpokePool", "Ethereum_SpokePool")
for CONTRACT in "${CONTRACTS[@]}"; do
    echo "Creating a storage layout snapshot of the $CONTRACT contract at ./storage-layouts/proposed.$CONTRACT.json"
    touch ./storage-layouts/proposed.$CONTRACT.json
    echo "Created temporary storage layout file at ./storage-layouts/proposed.$CONTRACT.json"
    forge inspect $CONTRACT storagelayout > ./storage-layouts/proposed.$CONTRACT.json
    echo "✅ 'forge inspect' command completed!"
    ## TODO: add an automatic check here like, if there is diff, throw error. This forces
    ## the developer to include the updated JSON file in the storage-layouts/ directory
    ## in their commit, assuming this script is running in CI.
    if ! diff -q "./storage-layouts/proposed.$CONTRACT.json" "./storage-layouts/$CONTRACT.json" &>/dev/null; then
        >&2 echo "diff detected in storage layout for $CONTRACT. Please update the storage layout file in the storage-layouts/ directory."
        exit 1
    fi
    echo "deleting ./storage-layouts/proposed.$CONTRACT.json"
    rm ./storage-layouts/proposed.$CONTRACT.json
done

exit 0

