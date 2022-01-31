// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

interface WETH9Like {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

/**
 * @title SpokePool
 * @notice Contract deployed on source and destination chains enabling depositors to transfer assets from source to
 * destination. Deposit orders are fulfilled by off-chain relayers who also interact with this contract. Deposited
 * tokens are locked on the source chain and relayers send the recipient the desired token currency and amount
 * on the destination chain. Locked source chain tokens are later sent over the canonical token bridge to L1.
 * @dev This contract is designed to be deployed to L2's, not mainnet.
 */
abstract contract SpokePool is Testable, Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    // Timestamp when contract was constructed. Relays cannot have a quote time before this.
    uint64 public deploymentTime;

    // Any deposit quote times greater than or less than this value to the current contract time is blocked. Forces
    // caller to use an up to date realized fee.
    uint64 public depositQuoteTimeBuffer;

    // Use count of deposits as unique deposit identifier.
    uint64 public numberOfDeposits;

    // Address of WETH contract for this network. If an origin token matches this, then the caller can optionally
    // instruct this contract to wrap ETH when depositing.
    WETH9Like public weth;

    // Origin token to destination token routings can be turned on or off.
    mapping(address => mapping(uint256 => bool)) public enabledDepositRoutes;

    struct RelayData {
        address sender;
        address recipient;
        address destinationToken;
        uint64 realizedLpFeePct;
        uint64 relayerFeePct;
        uint64 depositId;
        uint256 originChainId;
        uint256 relayAmount;
    }

    // Each relay is associated with the hash of parameters that uniquely identify the original deposit and a relay
    // attempt for that deposit. The relay itself is just represented as the amount filled so far. The total amount to 
    // relay, the fees, and the agents are all parameters included in the hash key.
    mapping(bytes32 => uint256) public relayFills;

    /****************************************
     *                EVENTS                *
     ****************************************/
    event EnabledDepositRoute(address indexed originToken, uint256 indexed destinationChainId, bool enabled);
    event SetDepositQuoteTimeBuffer(uint64 newBuffer);
    event FundsDeposited(
        uint256 destinationChainId,
        uint256 amount,
        uint64 indexed depositId,
        uint64 relayerFeePct,
        uint64 quoteTimestamp,
        address indexed originToken,
        address recipient,
        address indexed sender
    );
    event FilledRelay(
        bytes32 indexed relayHash,
        uint256 newFilledAmount,
        uint256 indexed repaymentChain,
        uint256 fillAmountNetFees,
        address indexed relayer,
        RelayData relayData
    );

    constructor(
        address timerAddress,
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer
    ) Testable(timerAddress) {
        deploymentTime = uint64(getCurrentTime());
        depositQuoteTimeBuffer = _depositQuoteTimeBuffer;
        weth = WETH9Like(_wethAddress);
    }

    /****************************************
     *               MODIFIERS              *
     ****************************************/

    modifier onlyEnabledRoute(address originToken, uint256 destinationId) {
        require(enabledDepositRoutes[originToken][destinationId], "Disabled route");
        _;
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    function _setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enabled
    ) internal {
        enabledDepositRoutes[originToken][destinationChainId] = enabled;
        emit EnabledDepositRoute(originToken, destinationChainId, enabled);
    }

    function _setDepositQuoteTimeBuffer(uint64 _depositQuoteTimeBuffer) internal {
        depositQuoteTimeBuffer = _depositQuoteTimeBuffer;
        emit SetDepositQuoteTimeBuffer(_depositQuoteTimeBuffer);
    }

    /**************************************
     *         DEPOSITOR FUNCTIONS        *
     **************************************/

    /**
     * @notice Called by user to bridge funds from origin to destination chain.
     * @dev The caller must first approve this contract to spend `amount` of `originToken`.
     */
    function deposit(
        address originToken,
        uint256 destinationChainId,
        uint256 amount,
        address recipient,
        uint64 relayerFeePct,
        uint64 quoteTimestamp
    ) public payable onlyEnabledRoute(originToken, destinationChainId) {
        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(relayerFeePct <= 0.5e18, "invalid relayer fee");
        // Note We assume that L2 timing cannot be compared accurately and consistently to L1 timing. Therefore,
        // `block.timestamp` is different from the L1 EVM's. Therefore, the quoteTimestamp must be within a configurable
        // buffer to allow for this variance.
        // Note also that `quoteTimestamp` cannot be less than the buffer otherwise the following arithmetic can result
        // in underflow. This isn't a problem as the deposit will revert, but the error might be unexpected for clients.
        require(
            getCurrentTime() >= quoteTimestamp - depositQuoteTimeBuffer &&
                getCurrentTime() <= quoteTimestamp + depositQuoteTimeBuffer,
            "invalid quote time"
        );
        // If the address of the origin token is a WETH contract and there is a msg.value with the transaction
        // then the user is sending ETH. In this case, the ETH should be deposited to WETH.
        if (originToken == address(weth) && msg.value > 0) {
            require(msg.value == amount, "msg.value must match amount");
            weth.deposit{ value: msg.value }();
        } else {
            // Else, it is a normal ERC20. In this case pull the token from the users wallet as per normal.
            // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them. In
            // this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
            IERC20(originToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit FundsDeposited(
            destinationChainId,
            amount,
            numberOfDeposits,
            relayerFeePct,
            quoteTimestamp,
            originToken,
            recipient,
            msg.sender
        );

        numberOfDeposits += 1;
    }

    function fillRelay(
        address sender,
        address recipient,
        address destinationToken,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint64 depositId,
        uint256 originChainId,
        uint256 relayAmount,
        uint256 fillAmount,
        uint256 repaymentChain
    ) public {
        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(relayerFeePct <= 0.5e18 && realizedLpFeePct <= 0.5e18, "invalid fees");

        // Each relay attempt is mapped to the hash of data uniquely identifying it, which includes the deposit data
        // such as the origin chain ID and the deposit ID, and the data in a relay attempt such as who the recipient
        // is, which chain and currency the recipient wants to receive funds on, and the relay fees. 
        RelayData memory relayData = RelayData({
            sender: sender,
            recipient: recipient,
            destinationToken: destinationToken,
            realizedLpFeePct: realizedLpFeePct,
            relayerFeePct: relayerFeePct,
            depositId: depositId,
            originChainId: originChainId,
            relayAmount: relayAmount
        });
        bytes32 relayHash = _getRelayHash(relayData);

        // Check that the caller is filling a non zero amount of the relay and that the filled amount will not
        // send to the recipient more than they are expected to receive. Note that the `relays` mapping will point
        // to the amount filled so far for a particular `relayHash`, so this will start at 0 and increment with each
        // fill.
        require(fillAmount > 0 && relayAmount >= relayFills[relayHash] + fillAmount, "Uninitialized or fully filled relay");

        // Update total filled amount with this new fill.
        relayFills[relayHash] += fillAmount;

        // Pull fill amount net fees from caller, which is the amount owed to the recipient. The relayer will receive
        // this amount plus the relayer fee after the relayer refund is processed.
        uint256 amountNetFees = fillAmount - _getAmountFromPct(realizedLpFeePct + relayerFeePct, fillAmount);

        // If relay token is weth then unwrap and send eth.
        if (destinationToken == address(weth)) {
            IERC20(destinationToken).safeTransferFrom(msg.sender, address(this), amountNetFees);
            _unwrapWETHTo(payable(recipient), amountNetFees);
            // Else, this is a normal ERC20 token. Send to recipient.
        } else IERC20(destinationToken).safeTransferFrom(msg.sender, recipient, amountNetFees);

        emit FilledRelay(
            relayHash,
            relayFills[relayHash],
            repaymentChain,
            amountNetFees,
            msg.sender,
            relayData
        );
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) public {}

    function distributeRelayerRefund(
        uint256 relayerRefundId,
        uint256 leafId,
        address l2TokenAddress,
        uint256 netSendAmount,
        address[] memory relayerRefundAddresses,
        uint256[] memory relayerRefundAmounts,
        bytes32[] memory inclusionProof
    ) public {}

    /**************************************
     *           VIEW FUNCTIONS           *
     **************************************/

    function chainId() public view returns (uint256) {
        return block.chainid;
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    function _getAmountFromPct(uint64 percent, uint256 amount) private pure returns (uint256) {
        return (percent * amount) / 1e18;
    }

    // Should we make this public for the relayer's convenience?
    function _getRelayHash(RelayData memory relayData) private pure returns (bytes32) {
        return keccak256(abi.encode(
            relayData
        ));
    }

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends WETH.
    function _unwrapWETHTo(address payable to, uint256 amount) internal {
        if (address(to).isContract()) {
            IERC20(address(weth)).safeTransfer(to, amount);
        } else {
            weth.withdraw(amount);
            to.transfer(amount);
        }
    }

    // Added to enable the this contract to receive ETH. Used when unwrapping Weth.
    receive() external payable {}

}
