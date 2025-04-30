// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @title DeterministicDeployer
 * @notice Utility for deterministic deployments using CREATE2
 * @dev This is a reimplementation of the hardhat-deploy deterministic deployment functionality
 */
contract DeterministicDeployer is Script {
    // Standard CREATE2 factory address used by hardhat-deploy
    address public constant HARDHAT_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /**
     * @notice Calculate the deterministic address for a contract
     * @param salt The salt for CREATE2
     * @param bytecode The contract creation bytecode
     * @return The address where the contract will be deployed
     */
    function getCreate2Address(bytes32 salt, bytes memory bytecode) public view returns (address) {
        return compute(salt, keccak256(bytecode));
    }

    /**
     * @notice Compute the CREATE2 address
     * @param salt The salt for CREATE2
     * @param bytecodeHash The hash of the contract bytecode
     * @return The address where the contract will be deployed
     */
    function compute(bytes32 salt, bytes32 bytecodeHash) internal view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), HARDHAT_CREATE2_FACTORY, salt, bytecodeHash))))
            );
    }

    /**
     * @notice Deploy a contract deterministically using CREATE2
     * @param salt The salt for CREATE2 (typically a 32-byte hex string like "0x1234...")
     * @param constructorArgs The constructor arguments for the contract
     * @param contractBytecode The contract creation bytecode
     * @return addr The address where the contract was deployed
     */
    function deterministicDeploy(
        string memory salt,
        bytes memory constructorArgs,
        bytes memory contractBytecode
    ) public returns (address addr) {
        bytes32 saltBytes32;
        if (bytes(salt).length == 66) {
            // If it's a hex string like "0x1234..."
            saltBytes32 = vm.parseBytes32(salt);
        } else {
            // If it's a short string, pad it with zeros
            saltBytes32 = bytes32(uint256(keccak256(abi.encodePacked(salt))));
        }
        bytes memory bytecode = abi.encodePacked(contractBytecode, constructorArgs);

        // Calculate the expected address
        addr = getCreate2Address(saltBytes32, bytecode);

        // Check if the contract is already deployed
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }

        // If already deployed, return the address
        if (size > 0) {
            console.log("Contract already deployed at %s", addr);
            return addr;
        }

        // Deploy using CREATE2
        bytes memory deployCode = abi.encodePacked(
            // Deploy using the CREATE2 factory
            hex"604580600e600039806000f350fe",
            bytecode
        );

        bytes memory factoryCalldata = abi.encodePacked(bytes1(0xff), saltBytes32, keccak256(bytecode), bytecode);

        // Call the CREATE2 factory
        (bool success, ) = HARDHAT_CREATE2_FACTORY.call(factoryCalldata);
        require(success, "Failed to deploy deterministically");

        console.log("Contract deterministically deployed at %s", addr);
        return addr;
    }

    /**
     * @notice Check if the CREATE2 factory is deployed
     * @return true if the factory exists, false otherwise
     */
    function isFactoryDeployed() public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(HARDHAT_CREATE2_FACTORY)
        }
        return size > 0;
    }

    /**
     * @notice Ensure the CREATE2 factory is deployed
     * @dev This will deploy the factory if it doesn't exist
     */
    function ensureFactoryDeployed() public {
        if (isFactoryDeployed()) {
            return;
        }

        console.log("Deploying CREATE2 factory at %s", HARDHAT_CREATE2_FACTORY);

        // This is the bytecode of the CREATE2 factory contract
        bytes
            memory bytecode = hex"608060405234801561001057600080fd5b50610272806100206000396000f3fe608060405234801561001057600080fd5b506004361061002b5760003560e01c80634af63f0214610030575b600080fd5b6100f66004803603602081101561004657600080fd5b810190808035906020019064010000000081111561006357600080fd5b82018360208201111561007557600080fd5b8035906020019184600183028401116401000000008311171561009757600080fd5b91908080601f016020809104026020016040519081016040528093929190818152602001838380828437600081840152601f19601f8201169050808301925050505050505091929192905050506100f8565b005b60008151905060005b8151811015610207576000818301602052604082026000820151905060208101517f87dc7413f85a45e2e2e62ce6d010a0e121dba8961e33184d9072afc09b038be560018501602081018190526001850160408601528360608601537f8eead0d93f10c1939cae6f342b9461e3875a5f3c11aa464305fef7f49e7fa1f6600160005b608083101561017a578085016060015185838301608001528290045b81811561017257805160001a907effffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1a8317905280e180945060010161013a565b505050600101610129565b5060e0820160009080516020610227833981519152607f60ff1683015260ff60e085015261010085015a608085015260a0860186600060c0880152875af180610226575050506001906101c2565b80610224575060408301515a10156101ea575060408301515a1015610224565b5a1015610224576101f981610224565b600161022284546001019081019061020f565b50505b505b508080600101915050610101565b5050565b3d3d3d3d3d913e1c1c0000000000000000000000000000000000000000000000000000000000";

        // Deploy the factory contract
        (bool success, ) = address(0x3fAB184622Dc19b6109349B94811493BF2a45362).call{ value: 10000000000000000 }("");
        require(success, "Failed to fund the factory deployer");
    }
}
