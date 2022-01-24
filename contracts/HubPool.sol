//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface WETH9Like {
    function withdraw(uint256 wad) external;

    function deposit() external payable;
}

contract HubPool is Testable, Lockable, MultiCaller, Ownable {
    struct LPToken {
        address lpToken;
        bool isWeth;
        bool isEnabled;
    }

    mapping(address => LPToken) public lpTokens; // Mapping of L1TokenAddress to the associated LPToken.

    constructor(address timerAddress) Testable(timerAddress) {}

    /*************************************************
     *                ADMIN FUNCTIONS                *
     *************************************************/

    // TODO: the two functions below should be called by the Admin contract.
    function enableL1TokenForLiquidityProvision(
        address l1Token,
        bool isWeth,
        string memory lpTokenName,
        string memory lpTokenSymbol
    ) public onlyOwner {
        ERC20 lpToken = new ERC20(lpTokenName, lpTokenSymbol);
        lpTokens[l1Token] = LPToken({ lpToken: address(lpToken), isWeth: isWeth, isEnabled: true });
    }

    function disableL1TokenForLiquidityProvision(address l1Token) public onlyOwner {
        lpTokens[l1Token].isEnabled = false;
    }

    // TODO: implement this. this will likely go into a separate Admin contract that contains all the L1->L2 Admin logic.
    // function setTokenToAcceptDeposits(address token) public {}

    /*************************************************
     *          LIQUIDITY PROVIDER FUNCTIONS         *
     *************************************************/

    function addLiquidity(address token, uint256 amount) public {}

    function exchangeRateCurrent(address token) public returns (uint256) {}

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
}
