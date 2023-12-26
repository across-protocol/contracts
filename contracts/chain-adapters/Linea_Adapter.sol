// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMessageService {
    /**
     * @notice Sends a message for transporting from the given chain.
     * @dev This function should be called with a msg.value = _value + _fee. The fee will be paid on the destination chain.
     * @param _to The destination address on the destination chain.
     * @param _fee The message service fee on the origin chain.
     * @param _calldata The calldata used by the destination message service to call the destination contract.
     */
    function sendMessage(
        address _to,
        uint256 _fee,
        bytes calldata _calldata
    ) external payable;
}

interface ITokenBridge {
    /**
     * @notice This function is the single entry point to bridge tokens to the
     *   other chain, both for native and already bridged tokens. You can use it
     *   to bridge any ERC20. If the token is bridged for the first time an ERC20
     *   (BridgedToken.sol) will be automatically deployed on the target chain.
     * @dev User should first allow the bridge to transfer tokens on his behalf.
     *   Alternatively, you can use `bridgeTokenWithPermit` to do so in a single
     *   transaction. If you want the transfer to be automatically executed on the
     *   destination chain. You should send enough ETH to pay the postman fees.
     *   Note that Linea can reserve some tokens (which use a dedicated bridge).
     *   In this case, the token cannot be bridged. Linea can only reserve tokens
     *   that have not been bridged yet.
     *   Linea can pause the bridge for security reason. In this case new bridge
     *   transaction would revert.
     * @param _token The address of the token to be bridged.
     * @param _amount The amount of the token to be bridged.
     * @param _recipient The address that will receive the tokens on the other chain.
     */
    function bridgeToken(
        address _token,
        uint256 _amount,
        address _recipient
    ) external payable;
}

interface IUSDCBridge {
    function usdc() external view returns (address);

    /**
     * @dev Sends the sender's USDC from L1 to the recipient on L2, locks the USDC sent
     * in this contract and sends a message to the message bridge
     * contract to mint the equivalent USDC on L2
     * @param amount The amount of USDC to send
     * @param to The recipient's address to receive the funds
     */
    function depositTo(uint256 amount, address to) external payable;
}

// solhint-disable-next-line contract-name-camelcase
contract Linea_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    WETH9Interface public immutable l1Weth;

    IMessageService public immutable l1MessageService;
    ITokenBridge public immutable l1TokenBridge;
    IUSDCBridge public immutable l1UsdcBridge;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _l1MessageService Canonical message service contract on L1.
     * @param _l1TokenBridge Canonical token bridge contract on L1.
     * @param _l1UsdcBridge L1 USDC Bridge to ConsenSys's L2 Linea.
     */
    constructor(
        WETH9Interface _l1Weth,
        IMessageService _l1MessageService,
        ITokenBridge _l1TokenBridge,
        IUSDCBridge _l1UsdcBridge
    ) {
        l1Weth = _l1Weth;
        l1MessageService = _l1MessageService;
        l1TokenBridge = _l1TokenBridge;
        l1UsdcBridge = _l1UsdcBridge;
    }

    /**
     * @notice Send cross-chain message to target on Linea.
     * @param target Contract on Linea that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        l1MessageService.sendMessage{ value: msg.value }(target, 0, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Linea.
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
        // If the l1Token is WETH then unwrap it to ETH then send the ETH directly
        // via the Canoncial Message Service.
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            l1MessageService.sendMessage{ value: amount }(to, 0, "");
        }
        // If the l1Token is USDC, then we need sent it via the USDC Bridge.
        else if (l1Token == l1UsdcBridge.usdc()) {
            IERC20(l1Token).safeIncreaseAllowance(address(l1UsdcBridge), amount);
            l1UsdcBridge.depositTo(amount, to);
        }
        // For other tokens, we can use the Canonical Token Bridge.
        else {
            IERC20(l1Token).safeIncreaseAllowance(address(l1TokenBridge), amount);
            l1TokenBridge.bridgeToken(l1Token, amount, to);
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
