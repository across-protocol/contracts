//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";
import { SpokePoolV3Periphery } from "../SpokePoolV3Periphery.sol";
import { PeripherySigningLib } from "../libraries/PeripherySigningLib.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";

interface SpokePoolV3PeripheryProxyInterface {
    function swapAndBridge(PeripherySigningLib.SwapAndDepositData calldata swapAndDepositData) external;
}

/**
 * @title SpokePoolV3Periphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @dev Variables which may be immutable are not marked as immutable, nor defined in the constructor, so that this
 * contract may be deployed deterministically at the same address across different networks.
 * @custom:security-contact bugs@across.to
 */
interface SpokePoolV3PeripheryInterface {
    function deposit(
        address recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes memory message
    ) external payable;

    function swapAndBridge(PeripherySigningLib.SwapAndDepositData calldata swapAndDepositData) external payable;

    function swapAndBridgeWithPermit(
        PeripherySigningLib.SwapAndDepositData calldata swapAndDepositData,
        uint256 deadline,
        bytes calldata permitSignature
    ) external;

    function swapAndBridgeWithPermit2(
        address signatureOwner,
        PeripherySigningLib.SwapAndDepositData calldata swapAndDepositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;

    function swapAndBridgeWithAuthorization(
        PeripherySigningLib.SwapAndDepositData calldata swapAndDepositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature
    ) external;

    function depositWithPermit(
        PeripherySigningLib.DepositData calldata depositData,
        uint256 deadline,
        bytes calldata permitSignature
    ) external;

    function depositWithPermit2(
        address signatureOwner,
        PeripherySigningLib.DepositData calldata depositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external;

    function depositWithAuthorization(
        PeripherySigningLib.DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature
    ) external;
}
