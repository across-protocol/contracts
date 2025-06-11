#!/usr/bin/env python3
"""
Script to extract deployed contract addresses from Foundry broadcast files.

This script reads from the broadcast folder and generates a file with the latest deployed 
smart contract addresses that are in the broadcast folder.

It specifically looks at the run-latest.json file for each smart contract and inside 
that JSON looks at the `contractAddress` field.
"""

import json
import os
import sys
from datetime import datetime
from pathlib import Path


def find_broadcast_files(broadcast_dir: Path) -> list:
    """Find all run-latest.json files in the broadcast directory structure."""
    broadcast_files = []
    
    # Walk through the broadcast directory
    for script_dir in broadcast_dir.iterdir():
        if script_dir.is_dir():
            # Each script has its own directory (e.g., DeployHubPool.s.sol)
            for chain_dir in script_dir.iterdir():
                if chain_dir.is_dir() and chain_dir.name.isdigit():
                    # Chain ID directories (e.g., 11155111 for Sepolia)
                    run_latest_path = chain_dir / "run-latest.json"
                    if run_latest_path.exists():
                        broadcast_files.append({
                            'script_name': script_dir.name,
                            'chain_id': int(chain_dir.name),
                            'file_path': run_latest_path
                        })
    
    return broadcast_files


def extract_contract_addresses(file_path: Path) -> list:
    """Extract contract addresses from a run-latest.json file."""
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
        
        contracts = []
        transactions = data.get('transactions', [])
        receipts = data.get('receipts', [])
        
        # Create a mapping of transaction hash to block number
        tx_hash_to_block = {}
        for receipt in receipts:
            tx_hash = receipt.get('transactionHash')
            block_number = receipt.get('blockNumber')
            if tx_hash and block_number:
                # Convert hex to decimal
                if isinstance(block_number, str) and block_number.startswith('0x'):
                    block_number = int(block_number, 16)
                tx_hash_to_block[tx_hash] = block_number
        
        for tx in transactions:
            if tx.get('transactionType') == 'CREATE' and tx.get('contractAddress'):
                tx_hash = tx.get('hash')
                block_number = tx_hash_to_block.get(tx_hash)
                
                contracts.append({
                    'contractName': tx.get('contractName', 'Unknown'),
                    'contractAddress': tx.get('contractAddress'),
                    'transactionHash': tx_hash,
                    'blockNumber': block_number
                })
        
        return contracts
    
    except Exception as e:
        print(f"Error reading {file_path}: {e}")
        return []


def get_chain_name(chain_id: int) -> str:
    """Get human-readable chain name from chain ID."""
    chain_names = {
        1: "Mainnet",
        11155111: "Sepolia",
        42161: "Arbitrum One",
        421614: "Arbitrum Sepolia",
        137: "Polygon",
        80002: "Polygon Amoy",
        10: "Optimism",
        11155420: "Optimism Sepolia",
        8453: "Base",
        84532: "Base Sepolia",
        56: "BSC",
        324: "zkSync Era",
        59144: "Linea",
        534352: "Scroll",
        534351: "Scroll Sepolia",
        81457: "Blast",
        168587773: "Blast Sepolia",
        # Add more chain IDs as needed
    }
    return chain_names.get(chain_id, f"Chain {chain_id}")


def generate_addresses_file(broadcast_files: list, output_file: Path) -> None:
    """Generate the deployed addresses file."""
    all_contracts = {}
    
    # Process each broadcast file
    for broadcast_file in broadcast_files:
        contracts = extract_contract_addresses(broadcast_file['file_path'])
        
        if contracts:
            chain_id = broadcast_file['chain_id']
            chain_name = get_chain_name(chain_id)
            script_name = broadcast_file['script_name']
            
            if chain_id not in all_contracts:
                all_contracts[chain_id] = {
                    'chain_name': chain_name,
                    'scripts': {}
                }
            
            all_contracts[chain_id]['scripts'][script_name] = contracts
    
    # Generate output content
    content = []
    content.append("# Deployed Contract Addresses")
    content.append("")
    content.append(f"Generated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    content.append("")
    content.append("This file contains the latest deployed smart contract addresses from the broadcast folder.")
    content.append("")
    
    # Sort by chain ID for consistent output
    for chain_id in sorted(all_contracts.keys()):
        chain_info = all_contracts[chain_id]
        content.append(f"## {chain_info['chain_name']} (Chain ID: {chain_id})")
        content.append("")
        
        for script_name, contracts in chain_info['scripts'].items():
            content.append(f"### {script_name}")
            content.append("")
            
            for contract in contracts:
                content.append(f"- **{contract['contractName']}**: `{contract['contractAddress']}`")
                content.append(f"  - Transaction Hash: `{contract['transactionHash']}`")
                if contract['blockNumber'] is not None:
                    content.append(f"  - Block Number: `{contract['blockNumber']}`")
                content.append("")
        
        content.append("")
    
    # Generate JSON format as well
    json_output = {
        'generated_at': datetime.now().isoformat(),
        'chains': {}
    }
    
    for chain_id, chain_info in all_contracts.items():
        json_output['chains'][str(chain_id)] = {
            'chain_name': chain_info['chain_name'],
            'contracts': {}
        }
        
        for script_name, contracts in chain_info['scripts'].items():
            for contract in contracts:
                contract_name = contract['contractName']
                json_output['chains'][str(chain_id)]['contracts'][contract_name] = {
                    'address': contract['contractAddress'],
                    'transaction_hash': contract['transactionHash'],
                    'block_number': contract['blockNumber']
                }
    
    # Write markdown file
    markdown_file = output_file.with_suffix('.md')
    with open(markdown_file, 'w') as f:
        f.write('\n'.join(content))
    
    # Write JSON file
    json_file = output_file.with_suffix('.json')
    with open(json_file, 'w') as f:
        json.dump(json_output, f, indent=2)
    
    print(f"Generated deployed addresses files:")
    print(f"  - Markdown: {markdown_file}")
    print(f"  - JSON: {json_file}")


def main():
    """Main function."""
    # Get the script directory and find broadcast folder
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    broadcast_dir = project_root / "broadcast"
    
    if not broadcast_dir.exists():
        print(f"Error: Broadcast directory not found at {broadcast_dir}")
        sys.exit(1)
    
    print(f"Scanning broadcast directory: {broadcast_dir}")
    
    # Find all broadcast files
    broadcast_files = find_broadcast_files(broadcast_dir)
    
    if not broadcast_files:
        print("No run-latest.json files found in broadcast directory")
        sys.exit(1)
    
    print(f"Found {len(broadcast_files)} broadcast files:")
    for bf in broadcast_files:
        print(f"  - {bf['script_name']} on {get_chain_name(bf['chain_id'])}")
    
    # Generate output file inside broadcast directory
    output_file = broadcast_dir / "deployed-addresses"
    generate_addresses_file(broadcast_files, output_file)
    
    print("\nDone!")


if __name__ == "__main__":
    main() 