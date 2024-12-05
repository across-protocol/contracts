// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library PeripherySigningLib {
    // Enum describing the method of transferring tokens to an exchange.
    enum TransferType {
        // Approve the exchange so that it may transfer tokens from this contract.
        Approval,
        // Transfer tokens to the exchange before calling it in this contract.
        Transfer,
        // Approve the exchange by use of an EIP1271 callback.
        EIP1271Signature
    }

    // Params we'll need caller to pass in to specify an Across Deposit. The input token will be swapped into first
    // before submitting a bridge deposit, which is why we don't include the input token amount as it is not known
    // until after the swap.
    struct BaseDepositData {
        // Token deposited on origin chain.
        address inputToken;
        // Token received on destination chain.
        address outputToken;
        // Amount of output token to be received by recipient.
        uint256 outputAmount;
        // The account credited with deposit who can submit speedups to the Across deposit.
        address depositor;
        // The account that will receive the output token on the destination chain. If the output token is
        // wrapped native token, then if this is an EOA then they will receive native token on the destination
        // chain and if this is a contract then they will receive an ERC20.
        address recipient;
        // The destination chain identifier.
        uint256 destinationChainId;
        // The account that can exclusively fill the deposit before the exclusivity parameter.
        address exclusiveRelayer;
        // Timestamp of the deposit used by system to charge fees. Must be within short window of time into the past
        // relative to this chain's current time or deposit will revert.
        uint32 quoteTimestamp;
        // The timestamp on the destination chain after which this deposit can no longer be filled.
        uint32 fillDeadline;
        // The timestamp or offset on the destination chain after which anyone can fill the deposit. A detailed description on
        // how the parameter is interpreted by the V3 spoke pool can be found at https://github.com/across-protocol/contracts/blob/fa67f5e97eabade68c67127f2261c2d44d9b007e/contracts/SpokePool.sol#L476
        uint32 exclusivityParameter;
        // Data that is forwarded to the recipient if the recipient is a contract.
        bytes message;
    }

    // Minimum amount of parameters needed to perform a swap on an exchange specified. We include information beyond just the router calldata
    // and exchange address so that we may ensure that the swap was performed properly.
    struct SwapAndDepositData {
        // Deposit data to use when interacting with the Across spoke pool.
        BaseDepositData depositData;
        // Token to swap.
        address swapToken;
        // Address of the exchange to use in the swap.
        address exchange;
        // Method of transferring tokens to the exchange.
        TransferType transferType;
        // Amount of the token to swap on the exchange.
        uint256 swapTokenAmount;
        // Minimum output amount of the exchange, and, by extension, the minimum required amount to deposit into an Across spoke pool.
        uint256 minExpectedInputTokenAmount;
        // The calldata to use when calling the exchange.
        bytes routerCalldata;
    }

    // Extended deposit data to be used specifically for signing off on periphery deposits.
    struct DepositData {
        // Deposit data describing the parameters for the V3 Across deposit.
        BaseDepositData baseDepositData;
        // The precise input amount to deposit into the spoke pool.
        uint256 inputAmount;
    }

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
        abi.encodePacked("DepositData(", "BaseDepositData baseDepositData", "uint256 inputAmount)");
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
    string internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token, uint256 amount)";
    string internal constant EIP712_SWAP_AND_DEPOSIT_TYPE_STRING =
        string(
            abi.encodePacked(
                "SwapAndDepositData witness)",
                EIP712_SWAP_AND_DEPOSIT_DATA_TYPE,
                EIP712_BASE_DEPOSIT_DATA_TYPE,
                TOKEN_PERMISSIONS_TYPE
            )
        );
    string internal constant EIP712_DEPOSIT_TYPE_STRING =
        string(
            abi.encodePacked(
                "DepositData witness)",
                EIP712_DEPOSIT_DATA_TYPE,
                EIP712_BASE_DEPOSIT_DATA_TYPE,
                TOKEN_PERMISSIONS_TYPE
            )
        );

    error InvalidSignature();

    /**
     * @notice Creates the EIP712 compliant hashed data corresponding to the BaseDepositData struct.
     * @param baseDepositData Input struct whose values are hashed.
     * @dev BaseDepositData is only used as a nested struct for both DepositData and SwapAndDepositData.
     */
    function hashBaseDepositData(BaseDepositData calldata baseDepositData) internal pure returns (bytes32) {
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
    function hashDepositData(DepositData calldata depositData) internal pure returns (bytes32) {
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
    function hashSwapAndDepositData(SwapAndDepositData calldata swapAndDepositData) internal pure returns (bytes32) {
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
