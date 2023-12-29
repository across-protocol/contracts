// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./libraries/CCTPAdapter.sol";
import "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Send tokens to Polygon.
 */
interface IRootChainManager {
    /**
     * @notice Send msg.value of ETH to Polygon
     * @param user Recipient of ETH on Polygon.
     */
    function depositEtherFor(address user) external payable;

    /**
     * @notice Send ERC20 tokens to Polygon.
     * @param user Recipient of L2 equivalent tokens on Polygon.
     * @param rootToken L1 Address of token to send.
     * @param depositData Data to pass to L2 including amount of tokens to send. Should be abi.encode(amount).
     */
    function depositFor(
        address user,
        address rootToken,
        bytes calldata depositData
    ) external;
}

/**
 * @notice Send arbitrary messages to Polygon.
 */
interface IFxStateSender {
    /**
     * @notice Send arbitrary message to Polygon.
     * @param _receiver Address on Polygon to receive message.
     * @param _data Message to send to `_receiver` on Polygon.
     */
    function sendMessageToChild(address _receiver, bytes calldata _data) external;
}

/**
 * @notice Similar to RootChainManager, but for Matic (Plasma) bridge.
 */
interface DepositManager {
    /**
     * @notice Send tokens to Polygon. Only used to send MATIC in this Polygon_Adapter.
     * @param token L1 token to send. Should be MATIC.
     * @param user Recipient of L2 equivalent tokens on Polygon.
     * @param amount Amount of `token` to send.
     */
    function depositERC20ForUser(
        address token,
        address user,
        uint256 amount
    ) external;
}

/**
 * @notice Sends cross chain messages Polygon L2 network.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract Polygon_Adapter is AdapterInterface, CCTPAdapter {
    using SafeERC20 for IERC20;
    IRootChainManager public immutable rootChainManager;
    IFxStateSender public immutable fxStateSender;
    DepositManager public immutable depositManager;
    address public immutable erc20Predicate;
    address public immutable l1Matic;
    WETH9Interface public immutable l1Weth;

    /**
     * @notice Constructs new Adapter.
     * @param _rootChainManager RootChainManager Polygon system contract to deposit tokens over the PoS bridge.
     * @param _fxStateSender FxStateSender Polygon system contract to send arbitrary messages to L2.
     * @param _depositManager DepositManager Polygon system contract to deposit tokens over the Plasma bridge (Matic).
     * @param _erc20Predicate ERC20Predicate Polygon system contract to approve when depositing to the PoS bridge.
     * @param _l1Matic matic address on l1.
     * @param _l1Weth WETH address on L1.
     * @param _l1Usdc USDC address on L1.
     * @param _circleDomain Circle domain set for this chain. NOTE: this is issued by circle and is irrelevant of chain id
     * @param _tokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    constructor(
        IRootChainManager _rootChainManager,
        IFxStateSender _fxStateSender,
        DepositManager _depositManager,
        address _erc20Predicate,
        address _l1Matic,
        WETH9Interface _l1Weth,
        IERC20 _l1Usdc,
        uint32 _circleDomain,
        ITokenMessenger _tokenMessenger
    ) CCTPAdapter(_l1Usdc, _circleDomain, _tokenMessenger) {
        rootChainManager = _rootChainManager;
        fxStateSender = _fxStateSender;
        depositManager = _depositManager;
        erc20Predicate = _erc20Predicate;
        l1Matic = _l1Matic;
        l1Weth = _l1Weth;
    }

    /**
     * @notice Send cross-chain message to target on Polygon.
     * @param target Contract on Polygon that will receive message.
     * @param message Data to send to target.
     */

    function relayMessage(address target, bytes calldata message) external payable override {
        fxStateSender.sendMessageToChild(target, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Polygon.
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
        // If the l1Token is weth then unwrap it to ETH then send the ETH to the standard bridge.
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            rootChainManager.depositEtherFor{ value: amount }(to);
        }
        // If the l1Token is USDC, then we send it to the CCTP bridge
        else if (_isL1Usdc(l1Token)) {
            _transferFromL1Usdc(to, amount);
        } else if (l1Token == l1Matic) {
            IERC20(l1Token).safeIncreaseAllowance(address(depositManager), amount);
            depositManager.depositERC20ForUser(l1Token, to, amount);
        } else {
            IERC20(l1Token).safeIncreaseAllowance(erc20Predicate, amount);
            rootChainManager.depositFor(to, l1Token, abi.encode(amount));
        }
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
