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

    // Associates relayer refund distribution proofs to unique IDs.
    mapping(uint256 => bytes32) public relayerRefundRoots;

    // Count of additions to `relayerRefundRoots`.
    uint256 public relayerRefundRootCount;

    // This is a 2D bitmap tracking which leafs in the relayer refund roots have been claimed, with max size of
    // 256 elements, limiting us to 256 relayer refund leafs per distribution proof.
    mapping(uint256 => uint256) public relayerRefundRootClaimsBitmap;

    struct RelayData {
        address depositor;
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
        address indexed depositor
    );
    event FilledRelay(
        bytes32 indexed relayHash,
        uint256 totalRelayAmount,
        uint256 totalFilledAmount,
        uint256 fillAmount,
        uint256 indexed repaymentChain,
        uint256 originChainId,
        uint64 depositId,
        uint64 relayerFeePct,
        uint64 realizedLpFeePct,
        address destinationToken,
        address indexed relayer,
        address depositor,
        address recipient
    );
    event InitializedRelayerRefund(uint256 indexed relayerRefundRootCount, bytes32 relayerRepaymentDistributionProof);

    constructor(
        address _wethAddress,
        uint64 _depositQuoteTimeBuffer,
        address timerAddress
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
        address depositor,
        address recipient,
        address destinationToken,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint64 depositId,
        uint256 originChainId,
        uint256 totalRelayAmount,
        uint256 maxTokensToSend,
        uint256 repaymentChain
    ) public {
        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(
            relayerFeePct <= 0.5e18 && realizedLpFeePct <= 0.5e18 && (relayerFeePct + realizedLpFeePct) < 1e18,
            "invalid fees"
        );

        // Each relay attempt is mapped to the hash of data uniquely identifying it, which includes the deposit data
        // such as the origin chain ID and the deposit ID, and the data in a relay attempt such as who the recipient
        // is, which chain and currency the recipient wants to receive funds on, and the relay fees.
        RelayData memory relayData = RelayData({
            depositor: depositor,
            recipient: recipient,
            destinationToken: destinationToken,
            realizedLpFeePct: realizedLpFeePct,
            relayerFeePct: relayerFeePct,
            depositId: depositId,
            originChainId: originChainId,
            relayAmount: totalRelayAmount
        });
        bytes32 relayHash = _getRelayHash(relayData);

        // Check that the caller is filling a non zero amount of the relay and the relay has not already been completely
        // filled. Note that the `relays` mapping will point to the amount filled so far for a particular `relayHash`,
        // so this will start at 0 and increment with each fill.
        require(maxTokensToSend > 0 && relayFills[relayHash] < totalRelayAmount, "Cannot send 0, or relay filled");

        // Stores the equivalent amount to be sent by the relayer before fees have been taken out.
        uint256 fillAmountPreFees = _computeAmountPreFees(maxTokensToSend, (realizedLpFeePct + relayerFeePct));

        // Adding brackets "stack too deep" solidity error.
        {
            // If user's specified max amount to send is greater than the amount of the relay remaining pre-fees,
            // we'll pull exactly enough tokens to complete the relay.
            uint256 amountToSend = maxTokensToSend;
            if (totalRelayAmount - relayFills[relayHash] < fillAmountPreFees) {
                fillAmountPreFees = totalRelayAmount - relayFills[relayHash];
                amountToSend = _computeAmountPostFees(fillAmountPreFees, (realizedLpFeePct + relayerFeePct));
            }
            relayFills[relayHash] += fillAmountPreFees;
            // If relay token is weth then unwrap and send eth.
            if (destinationToken == address(weth)) {
                IERC20(destinationToken).safeTransferFrom(msg.sender, address(this), amountToSend);
                _unwrapWETHTo(payable(recipient), amountToSend);
                // Else, this is a normal ERC20 token. Send to recipient.
            } else IERC20(destinationToken).safeTransferFrom(msg.sender, recipient, amountToSend);
        }

        emit FilledRelay(
            relayHash,
            relayData.relayAmount,
            relayFills[relayHash],
            fillAmountPreFees,
            repaymentChain,
            relayData.originChainId,
            relayData.depositId,
            relayData.relayerFeePct,
            relayData.realizedLpFeePct,
            relayData.destinationToken,
            msg.sender,
            relayData.depositor,
            relayData.recipient
        );
    }

    // This internal method should be called by an external "initializeRelayerRefund" function that validates the
    // cross domain sender is the HubPool. This validation step differs for each L2, which is why the implementation
    // specifics are left to the implementor of this abstract contract.
    function _initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) internal {
        relayerRefundRoots[relayerRefundRootCount] = relayerRepaymentDistributionProof;
        emit InitializedRelayerRefund(relayerRefundRootCount, relayerRepaymentDistributionProof);
        relayerRefundRootCount += 1;
    }

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

    function _computeAmountPreFees(uint256 amount, uint256 feesPct) private pure returns (uint256) {
        return (1e18 * amount) / (1e18 - feesPct);
    }

    function _computeAmountPostFees(uint256 amount, uint256 feesPct) private pure returns (uint256) {
        return (amount * (1e18 - feesPct)) / 1e18;
    }

    // Should we make this public for the relayer's convenience?
    function _getRelayHash(RelayData memory relayData) private pure returns (bytes32) {
        return keccak256(abi.encode(relayData));
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
