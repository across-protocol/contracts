// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SpokePoolV3PeripheryInterface } from "../interfaces/SpokePoolV3PeripheryInterface.sol";

library PeripherySigningLib {
    // Typed structured data for the structs to sign against in the periphery.
    bytes internal constant EIP712_BASE_DEPOSIT_DATA_TYPE =
        abi.encodePacked(
            "BaseDepositData(",
            "address inputToken",
            "address outputToken",
            "uint256 outputAmount",
            "address depositor",
            "address recipient",
            "uint256 destinationChainId",
            "address exclusiveRelayer",
            "uint32 quoteTimestamp",
            "uint32 fillDeadline",
            "uint32 exclusivityParameter",
            "bytes message)"
        );
    bytes internal constant EIP712_DEPOSIT_DATA_TYPE =
        abi.encodePacked("DepositData(BaseDepositData baseDepositData,uint256 inputAmount)");
    bytes internal constant EIP712_SWAP_AND_DEPOSIT_DATA_TYPE =
        abi.encodePacked(
            "SwapAndDepositData(",
            "BaseDepositData depositData",
            "address swapToken",
            "address exchange",
            "TransferType transferType",
            "uint256 swapTokenAmount",
            "uint256 minExpectedInputTokenAmount",
            "bytes routerCalldata)"
        );

    // EIP712 Type hashes.
    bytes32 internal constant EIP712_DEPOSIT_DATA_TYPEHASH =
        keccak256(abi.encode(EIP712_DEPOSIT_DATA_TYPE, EIP712_BASE_DEPOSIT_DATA_TYPE));
    bytes32 internal constant EIP712_SWAP_AND_DEPOSIT_DATA_TYPEHASH =
        keccak256(abi.encode(EIP712_SWAP_AND_DEPOSIT_DATA_TYPE, EIP712_BASE_DEPOSIT_DATA_TYPE));

    // EIP712 Type strings.
    string internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";
    string internal constant EIP712_SWAP_AND_DEPOSIT_TYPE_STRING =
        string(
            abi.encodePacked(
                "SwapAndDepositData witness)",
                EIP712_BASE_DEPOSIT_DATA_TYPE,
                EIP712_SWAP_AND_DEPOSIT_DATA_TYPE,
                TOKEN_PERMISSIONS_TYPE
            )
        );
    string internal constant EIP712_DEPOSIT_TYPE_STRING =
        string(
            abi.encodePacked(
                "DepositData witness)",
                EIP712_BASE_DEPOSIT_DATA_TYPE,
                EIP712_DEPOSIT_DATA_TYPE,
                TOKEN_PERMISSIONS_TYPE
            )
        );

    error InvalidSignature();

    /**
     * @notice Creates the EIP712 compliant hashed data corresponding to the BaseDepositData struct.
     * @param baseDepositData Input struct whose values are hashed.
     * @dev BaseDepositData is only used as a nested struct for both DepositData and SwapAndDepositData.
     */
    function hashBaseDepositData(SpokePoolV3PeripheryInterface.BaseDepositData calldata baseDepositData)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    EIP712_BASE_DEPOSIT_DATA_TYPE,
                    baseDepositData.outputToken,
                    baseDepositData.outputAmount,
                    baseDepositData.depositor,
                    baseDepositData.recipient,
                    baseDepositData.destinationChainId,
                    baseDepositData.exclusiveRelayer,
                    baseDepositData.quoteTimestamp,
                    baseDepositData.fillDeadline,
                    baseDepositData.exclusivityParameter,
                    keccak256(baseDepositData.message)
                )
            );
    }

    /**
     * @notice Creates the EIP712 compliant hashed data corresponding to the DepositData struct.
     * @param depositData Input struct whose values are hashed.
     */
    function hashDepositData(SpokePoolV3PeripheryInterface.DepositData calldata depositData)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    EIP712_DEPOSIT_DATA_TYPE,
                    hashBaseDepositData(depositData.baseDepositData),
                    depositData.inputAmount
                )
            );
    }

    /**
     * @notice Creates the EIP712 compliant hashed data corresponding to the SwapAndDepositData struct.
     * @param swapAndDepositData Input struct whose values are hashed.
     */
    function hashSwapAndDepositData(SpokePoolV3PeripheryInterface.SwapAndDepositData calldata swapAndDepositData)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    EIP712_SWAP_AND_DEPOSIT_DATA_TYPEHASH,
                    hashBaseDepositData(swapAndDepositData.depositData),
                    swapAndDepositData.swapToken,
                    swapAndDepositData.exchange,
                    swapAndDepositData.transferType,
                    swapAndDepositData.swapTokenAmount,
                    swapAndDepositData.minExpectedInputTokenAmount,
                    keccak256(swapAndDepositData.routerCalldata)
                )
            );
    }

    /**
     * @notice Reads an input bytes, and, assuming it is a signature for a 32-byte hash, returns the v, r, and s values.
     * @param _signature The input signature to deserialize.
     */
    function deserializeSignature(bytes calldata _signature)
        internal
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        if (_signature.length != 65) revert InvalidSignature();
        v = uint8(_signature[64]);
        r = bytes32(_signature[0:32]);
        s = bytes32(_signature[32:64]);
    }
}
