//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface WETH9Like {
    function withdraw(uint256 wad) external;

    function deposit() external payable;
}

contract HubPool is Testable, Lockable, MultiCaller, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    struct LPToken {
        ExpandedERC20 lpToken;
        bool isEnabled;
    }

    WETH9Like public l1Weth;

    mapping(address => LPToken) public lpTokens; // Mapping of L1TokenAddress to the associated LPToken.

    event LiquidityAdded(address l1Token, uint256 amount, uint256 lpTokensMinted, address indexed liquidityProvider);
    event LiquidityRemoved(uint256 amount, uint256 lpTokensBurnt, address indexed liquidityProvider);

    constructor(address _l1Weth, address _timerAddress) Testable(_timerAddress) {
        l1Weth = WETH9Like(_l1Weth);
    }

    /*************************************************
     *                ADMIN FUNCTIONS                *
     *************************************************/

    // TODO: the two functions below should be called by the Admin contract.
    function enableL1TokenForLiquidityProvision(address l1Token) public onlyOwner {
        ExpandedERC20 lpToken = new ExpandedERC20(
            append("Across ", IERC20Metadata(l1Token).name(), " LP Token"), // LP Token Name
            append("Av2-", IERC20Metadata(l1Token).symbol(), "-LP"), // LP Token Symbol
            IERC20Metadata(l1Token).decimals() // LP Token Decimals
        );
        lpToken.addMember(1, address(this)); // Set this contract as the LP Token's minter.
        lpToken.addMember(2, address(this)); // Set this contract as the LP Token's burner.
        lpTokens[l1Token] = LPToken({ lpToken: lpToken, isEnabled: true });
    }

    function disableL1TokenForLiquidityProvision(address l1Token) public onlyOwner {
        lpTokens[l1Token].isEnabled = false;
    }

    // TODO: implement this. this will likely go into a separate Admin contract that contains all the L1->L2 Admin logic.
    // function setTokenToAcceptDeposits(address token) public {}

    /*************************************************
     *          LIQUIDITY PROVIDER FUNCTIONS         *
     *************************************************/

    function addLiquidity(address l1Token, uint256 l1TokenAmount) public payable {
        require(lpTokens[l1Token].isEnabled);
        // If this is the weth pool and the caller sends msg.value then the msg.value must match the l1TokenAmount.
        // Else, msg.value must be set to 0.
        require((address(l1Token) == address(l1Weth) && msg.value == l1TokenAmount) || msg.value == 0, "Bad msg.value");

        // Since `exchangeRateCurrent()` reads this contract's balance and updates contract state using it,
        // we must call it first before transferring any tokens to this contract.
        uint256 lpTokensToMint = (l1TokenAmount * 1e18) / _exchangeRateCurrent();
        ExpandedERC20(lpTokens[l1Token].lpToken).mint(msg.sender, lpTokensToMint);
        // liquidReserves += l1TokenAmount; //TODO: Add this when we have the liquidReserves variable implemented.

        if (address(l1Token) == address(l1Weth) && msg.value > 0)
            WETH9Like(address(l1Token)).deposit{ value: msg.value }();
        else IERC20(l1Token).safeTransferFrom(msg.sender, address(this), l1TokenAmount);

        emit LiquidityAdded(l1Token, l1TokenAmount, lpTokensToMint, msg.sender);
    }

    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) public nonReentrant {
        // Can only send eth on withdrawing liquidity iff this is the WETH pool.
        require(l1Token == address(l1Weth) || !sendEth, "Cant send eth");
        uint256 l1TokensToReturn = (lpTokenAmount * _exchangeRateCurrent()) / 1e18;

        // Check that there is enough liquid reserves to withdraw the requested amount.
        // require(liquidReserves >= (pendingReserves + l1TokensToReturn), "Utilization too high to remove"); // TODO: add this when we have liquid reserves variable implemented.

        ExpandedERC20(lpTokens[l1Token].lpToken).burnFrom(msg.sender, lpTokenAmount);
        // liquidReserves -= l1TokensToReturn; // TODO: add this when we have liquid reserves variable implemented.

        if (sendEth) _unwrapWETHTo(payable(msg.sender), l1TokensToReturn);
        else IERC20(l1Token).safeTransfer(msg.sender, l1TokensToReturn);

        emit LiquidityRemoved(l1TokensToReturn, lpTokenAmount, msg.sender);
    }

    function exchangeRateCurrent() public nonReentrant returns (uint256) {
        return _exchangeRateCurrent();
    }

    function liquidityUtilizationPostRelay(address token, uint256 relayedAmount) public returns (uint256) {}

    function initiateRelayerRefund(
        uint256[] memory bundleEvaluationBlockNumberForChain,
        bytes32 chainBatchRepaymentProof,
        bytes32 relayerRepaymentDistributionProof
    ) public {}

    function executeRelayerRefund(
        uint256 relayerRefundRequestId,
        uint256 leafId,
        uint256 repaymentChainId,
        address[] memory l1TokenAddress,
        uint256[] memory accumulatedLpFees,
        uint256[] memory netSendAmounts,
        bytes32[] memory inclusionProof
    ) public {}

    function _exchangeRateCurrent() internal pure returns (uint256) {
        return 1e18;
    }

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends WETH.
    function _unwrapWETHTo(address payable to, uint256 amount) internal {
        if (address(to).isContract()) {
            IERC20(address(l1Weth)).safeTransfer(to, amount);
        } else {
            l1Weth.withdraw(amount);
            to.transfer(amount);
        }
    }

    function append(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
    }

    // Added to enable the BridgePool to receive ETH. used when unwrapping Weth.
    receive() external payable {}
}
