// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";
import "../external/interfaces/IPolygonZkEVMBridge.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// solhint-disable-next-line contract-name-camelcase
contract PolygonZkEVM_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    WETH9Interface public immutable L1_WETH;
    // Address of Polygon zkEVM's Canonical Bridge on L1.
    IPolygonZkEVMBridge public immutable L1_POLYGON_ZKEVM_BRIDGE;

    // Polygon's internal network id for zkEVM.
    uint32 public constant POLYGON_ZKEVM_L2_NETWORK_ID = 1;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _l1PolygonZkEVMBridge Canonical token bridge contract on L1.
     */
    constructor(WETH9Interface _l1Weth, IPolygonZkEVMBridge _l1PolygonZkEVMBridge) {
        L1_WETH = _l1Weth;
        L1_POLYGON_ZKEVM_BRIDGE = _l1PolygonZkEVMBridge;
    }

    /**
     * @notice Send cross-chain message to target on Polygon zkEVM.
     * @param target Contract on Polygon zkEVM that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        L1_POLYGON_ZKEVM_BRIDGE.bridgeMessage(POLYGON_ZKEVM_L2_NETWORK_ID, target, true, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Polygon zkEVM.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        // The mapped WETH address in the native Polygon zkEVM bridge contract does not match
        // the official WETH address. Therefore, if the l1Token is WETH then unwrap it to ETH
        // and send the ETH directly via as msg.value.
        if (l1Token == address(L1_WETH)) {
            L1_WETH.withdraw(amount);
            L1_POLYGON_ZKEVM_BRIDGE.bridgeAsset{ value: amount }(
                POLYGON_ZKEVM_L2_NETWORK_ID,
                to,
                amount,
                address(0),
                true,
                ""
            );
        } else {
            IERC20(l1Token).safeIncreaseAllowance(address(L1_POLYGON_ZKEVM_BRIDGE), amount);
            L1_POLYGON_ZKEVM_BRIDGE.bridgeAsset(POLYGON_ZKEVM_L2_NETWORK_ID, to, amount, l1Token, true, "");
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
