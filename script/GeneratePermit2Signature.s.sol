// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script, console } from "forge-std/Script.sol";
import { IPermit2 } from "../contracts/external/interfaces/IPermit2.sol";
import { SpokePoolPeripheryInterface } from "../contracts/interfaces/SpokePoolPeripheryInterface.sol";

/**
 * @notice Generates a Permit2 witness signature for use with SpokePoolPeriphery.depositWithPermit2().
 * @dev Usage:
 *   forge script script/GeneratePermit2Signature.s.sol --rpc-url mainnet -vvv
 *
 *   Edit the params below before running.
 */
contract GeneratePermit2Signature is Script {
    // Canonical Permit2 on all chains
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // PermitWitnessTransferFrom typehash used by Permit2. Built by concatenating:
    //   "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,<witnessType>)"
    // where <witnessType> is the full witness type string (DepositData + nested types + TokenPermissions, sorted).
    bytes32 constant _PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH =
        keccak256(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,DepositData witness)BaseDepositData(address inputToken,bytes32 outputToken,uint256 outputAmount,address depositor,bytes32 recipient,uint256 destinationChainId,bytes32 exclusiveRelayer,uint32 quoteTimestamp,uint32 fillDeadline,uint32 exclusivityParameter,bytes message)DepositData(Fees submissionFees,BaseDepositData baseDepositData,uint256 inputAmount,address spokePool,uint256 nonce)Fees(uint256 amount,address recipient)TokenPermissions(address token,uint256 amount)"
        );

    bytes32 constant _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    // EIP712 typehashes matching PeripherySigningLib
    bytes32 constant EIP712_FEES_TYPEHASH = keccak256(abi.encodePacked("Fees(uint256 amount,address recipient)"));
    bytes32 constant EIP712_BASE_DEPOSIT_DATA_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "BaseDepositData(address inputToken,bytes32 outputToken,uint256 outputAmount,address depositor,bytes32 recipient,uint256 destinationChainId,bytes32 exclusiveRelayer,uint32 quoteTimestamp,uint32 fillDeadline,uint32 exclusivityParameter,bytes message)"
            )
        );
    bytes32 constant EIP712_DEPOSIT_DATA_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "DepositData(Fees submissionFees,BaseDepositData baseDepositData,uint256 inputAmount,address spokePool,uint256 nonce)",
                "BaseDepositData(address inputToken,bytes32 outputToken,uint256 outputAmount,address depositor,bytes32 recipient,uint256 destinationChainId,bytes32 exclusiveRelayer,uint32 quoteTimestamp,uint32 fillDeadline,uint32 exclusivityParameter,bytes message)",
                "Fees(uint256 amount,address recipient)"
            )
        );

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 signerKey = vm.deriveKey(deployerMnemonic, 0);
        address signer = vm.addr(signerKey);

        // ========================
        // === EDIT PARAMS HERE ===
        // ========================

        address periphery = 0x767e4c20F521a829dE4Ffc40C25176676878147f;
        address spokePool = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
        address inputToken = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
        uint256 inputAmount = 1000000;
        bytes32 outputToken = bytes32(uint256(uint160(0xaf88d065e77c8cC2239327C5EDb3A432268e5831)));
        uint256 outputAmount = 1000000;
        bytes32 recipient = bytes32(uint256(uint160(signer)));
        uint256 destinationChainId = 42161;
        bytes32 exclusiveRelayer = bytes32(0);
        uint32 quoteTimestamp = uint32(block.timestamp);
        uint32 fillDeadline = uint32(block.timestamp + 7200);
        uint32 exclusivityParameter = 0;
        uint256 permitNonce = 574821394205549330478458233681983755283309575853981330921020476261988176980;
        uint256 permitDeadline = block.timestamp + 3600;
        uint256 feeAmount = 0;
        address feeRecipient = address(0);
        bytes memory message = "";

        // ========================
        // === BUILD & SIGN     ===
        // ========================

        SpokePoolPeripheryInterface.DepositData memory depositData = SpokePoolPeripheryInterface.DepositData({
            submissionFees: SpokePoolPeripheryInterface.Fees({ amount: feeAmount, recipient: feeRecipient }),
            baseDepositData: SpokePoolPeripheryInterface.BaseDepositData({
                inputToken: inputToken,
                outputToken: outputToken,
                outputAmount: outputAmount,
                depositor: signer,
                recipient: recipient,
                destinationChainId: destinationChainId,
                exclusiveRelayer: exclusiveRelayer,
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                exclusivityParameter: exclusivityParameter,
                message: message
            }),
            inputAmount: inputAmount,
            spokePool: spokePool,
            nonce: permitNonce
        });

        bytes32 witness = _hashDepositData(depositData);

        // Permit2 EIP712 domain
        bytes32 permit2DomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                block.chainid,
                PERMIT2
            )
        );

        // Token permissions (permitted.amount includes submission fees)
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, inputToken, inputAmount + feeAmount)
        );

        // PermitWitnessTransferFrom struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH,
                tokenPermissionsHash,
                periphery, // spender
                permitNonce,
                permitDeadline,
                witness
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2DomainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // ========================
        // === CALL DEPOSIT     ===
        // ========================

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: inputToken, amount: inputAmount + feeAmount }),
            nonce: permitNonce,
            deadline: permitDeadline
        });

        console.log("=== Calling depositWithPermit2 ===");
        console.log("Signer:", signer);
        console.log("Periphery:", periphery);
        console.log("Input Token:", inputToken);
        console.log("Input Amount:", inputAmount);
        console.log("Destination Chain:", destinationChainId);

        vm.broadcast(signerKey);
        SpokePoolPeripheryInterface(periphery).depositWithPermit2(signer, depositData, permit, signature);

        console.log("depositWithPermit2 submitted successfully");
    }

    function _hashDepositData(SpokePoolPeripheryInterface.DepositData memory d) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DEPOSIT_DATA_TYPEHASH,
                    _hashFees(d.submissionFees),
                    _hashBaseDepositData(d.baseDepositData),
                    d.inputAmount,
                    d.spokePool,
                    d.nonce
                )
            );
    }

    function _hashFees(SpokePoolPeripheryInterface.Fees memory f) internal pure returns (bytes32) {
        return keccak256(abi.encode(EIP712_FEES_TYPEHASH, f.amount, f.recipient));
    }

    function _hashBaseDepositData(
        SpokePoolPeripheryInterface.BaseDepositData memory b
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_BASE_DEPOSIT_DATA_TYPEHASH,
                    b.inputToken,
                    b.outputToken,
                    b.outputAmount,
                    b.depositor,
                    b.recipient,
                    b.destinationChainId,
                    b.exclusiveRelayer,
                    b.quoteTimestamp,
                    b.fillDeadline,
                    b.exclusivityParameter,
                    keccak256(b.message)
                )
            );
    }
}
