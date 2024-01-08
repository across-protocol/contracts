#!/bin/bash

CONTRACT=$1
if [ -z "$CONTRACT" ]
then
  echo "Error: CONTRACT should be name of contract that you want to inspect storage layout of. e.g. Arbitrum_SpokePool"
  exit 1
fi

echo "Creating a storage layout snapshot of the $CONTRACT contract at ./storage-layouts/proposed.$CONTRACT.json"
echo "⏳ This can take a few minutes to complete if you haven't run a forge command recently"
touch ./storage-layouts/proposed.$CONTRACT.json
forge inspect $CONTRACT storagelayout > ./storage-layouts/proposed.$CONTRACT.json
echo "✅ Done!"

read -r -p "Do you want to run a diff on the proposed storage layout with the deployed one? [y/N] " response
case "$response" in
    [yY][eE][sS]|[yY]) 
        vim -d ./storage-layouts/proposed.$CONTRACT.json ./storage-layouts/$CONTRACT.json
        ;;
    *)
        ;;
esac

exit 0

