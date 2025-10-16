//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { CoreTokenInfo } from "./Structs.sol";

contract HyperCoreForwarder is Ownable {
    /// @notice A mapping of token addresses to their core token info.
    mapping(address => CoreTokenInfo) public coreTokenInfos;

    DonationBox public immutable donationBox;

    event DonationBoxInsufficientFunds(address token, uint256 amount);

    event SimpleTransferToCore(
        bytes32 quoteNonce,
        uint256 finalAmount,
        uint256 amountSponsored,
        address finalRecipient,
        address finalToken
    );

    constructor(address _donationBox) {
        donationBox = DonationBox(_donationBox);
    }

    function executeSimpleTransferToCore(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        address finalToken,
        uint256 extraFeesToSponsor
    ) external {
        CoreTokenInfo storage coreTokenInfo = coreTokenInfos[finalToken];

        uint256 maxFee = (amount * maxBpsToSponsor) / 10000;
        uint256 accountActivationFee = _getAccountActivationFee(finalToken, finalRecipient);
        uint256 amountToSponsor = extraFeesToSponsor + accountActivationFee;
        if (amountToSponsor > maxFee) {
            amountToSponsor = maxFee;
        }

        if (amountToSponsor > 0) {
            // TODO: implement a function to withdraw funds from the donation box
            try donationBox.withdraw(IERC20(coreTokenInfo.tokenInfo.evmContract), amountToSponsor) {
                // success: full sponsorship amount withdrawn to this contract
            } catch {
                emit DonationBoxInsufficientFunds(coreTokenInfo.tokenInfo.evmContract, amountToSponsor);
                amountToSponsor = 0;
            }
        }

        uint256 finalAmount = amount + amountToSponsor;

        HyperCoreLib.transferERC20EVMToCore(
            finalToken,
            coreTokenInfo.coreIndex,
            finalRecipient,
            finalAmount,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleTransferToCore(quoteNonce, finalAmount, amountToSponsor, finalRecipient, finalToken);
    }

    function _getAccountActivationFee(address token, address recipient) internal view returns (uint256) {
        bool accountActivated = HyperCoreLib.coreUserExists(recipient);

        // TODO: handle the case where the token can't be used for account activation
        return accountActivated ? 0 : coreTokenInfos[token].accountActivationFee;
    }
}
