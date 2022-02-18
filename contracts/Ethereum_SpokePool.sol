//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

/**
 * @notice Ethereum L1 specific SpokePool.
 * @dev Used on Ethereum L1 to facilitate L2->L1 transfers.
 */

contract Ethereum_SpokePool is SpokePoolInterface, SpokePool, Ownable {
    constructor(
        address _l1EthWrapper,
        address _l2Eth,
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    function _chainId() internal view override returns (uint256) {
        return block.chainid;
    }

    function _verifyDepositorUpdateFeeMessage(
        address depositor,
        bytes32 ethSignedMessageHash,
        bytes memory depositorSignature
    ) internal view override {
        _defaultVerifyDepositorUpdateFeeMessage(depositor, ethSignedMessageHash, depositorSignature);
    }

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override onlyOwner nonReentrant {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override onlyOwner nonReentrant {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) public override onlyOwner nonReentrant {
        _setEnableRoute(originToken, destinationChainId, enable);
    }

    function setDepositQuoteTimeBuffer(uint32 buffer) public override onlyOwner nonReentrant {
        _setDepositQuoteTimeBuffer(buffer);
    }

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionRoot, bytes32 slowRelayRoot)
        public
        override
        onlyOwner
        nonReentrant
    {
        _initializeRelayerRefund(relayerRepaymentDistributionRoot, slowRelayRoot);
    }

    function _bridgeTokensToHubPool(DestinationDistributionLeaf memory distributionLeaf) internal override {
        IERC20(distributionLeaf.l2TokenAddress).transfer(hubPool, distributionLeaf.amountToReturn);
    }
}
