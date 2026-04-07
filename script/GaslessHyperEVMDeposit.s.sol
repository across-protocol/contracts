// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SpokePoolPeripheryInterface } from "../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { AddressToBytes32 } from "../contracts/libraries/AddressConverters.sol";

/// @notice Query EIP-712 domain separator from EIP-3009/2612 tokens or Permit2.
interface IERC712DomainSeparator {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function domainSeparator() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
}

/// @notice Memory-compatible hashing for SpokePoolPeriphery types.
/// @dev PeripherySigningLib uses calldata args; scripts need memory.
library MemPeripheryHash {
    bytes32 internal constant EIP712_FEES_TYPEHASH =
        keccak256(abi.encodePacked("Fees(uint256 amount,address recipient)"));

    bytes32 internal constant EIP712_BASE_DEPOSIT_DATA_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "BaseDepositData(address inputToken,bytes32 outputToken,uint256 outputAmount,address depositor,"
                "bytes32 recipient,uint256 destinationChainId,bytes32 exclusiveRelayer,uint32 quoteTimestamp,"
                "uint32 fillDeadline,uint32 exclusivityParameter,bytes message)"
            )
        );

    bytes32 internal constant EIP712_DEPOSIT_DATA_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "DepositData(Fees submissionFees,BaseDepositData baseDepositData,uint256 inputAmount,"
                "address spokePool,uint256 nonce)",
                "BaseDepositData(address inputToken,bytes32 outputToken,uint256 outputAmount,address depositor,"
                "bytes32 recipient,uint256 destinationChainId,bytes32 exclusiveRelayer,uint32 quoteTimestamp,"
                "uint32 fillDeadline,uint32 exclusivityParameter,bytes message)",
                "Fees(uint256 amount,address recipient)"
            )
        );

    function hashFees(SpokePoolPeripheryInterface.Fees memory fees) internal pure returns (bytes32) {
        return keccak256(abi.encode(EIP712_FEES_TYPEHASH, fees.amount, fees.recipient));
    }

    function hashBaseDepositData(SpokePoolPeripheryInterface.BaseDepositData memory d) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_BASE_DEPOSIT_DATA_TYPEHASH,
                    d.inputToken,
                    d.outputToken,
                    d.outputAmount,
                    d.depositor,
                    d.recipient,
                    d.destinationChainId,
                    d.exclusiveRelayer,
                    d.quoteTimestamp,
                    d.fillDeadline,
                    d.exclusivityParameter,
                    keccak256(d.message)
                )
            );
    }

    function hashDepositData(SpokePoolPeripheryInterface.DepositData memory d) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DEPOSIT_DATA_TYPEHASH,
                    hashFees(d.submissionFees),
                    hashBaseDepositData(d.baseDepositData),
                    d.inputAmount,
                    d.spokePool,
                    d.nonce
                )
            );
    }
}

/*
Gasless HyperEVM Deposit Script (ACP-69)

Tests two gasless deposit flows on HyperEVM:
  1. EIP-3009 (receiveWithAuthorization) — for tokens like USDC
  2. Permit2 — for standard ERC20 tokens after Permit2 approval

Also supports submitting Hyperliquid API spotSend (Core -> user's HyperEVM address).

Environment variables (shared):
  MNEMONIC             Mnemonic (index 0 = user, BOT_INDEX = bot)
  PERIPHERY            SpokePoolPeriphery address on HyperEVM
  SPOKE_POOL           SpokePool address on HyperEVM
  INPUT_TOKEN          Token address on HyperEVM
  DESTINATION_CHAIN    Destination chain ID for Across deposit

Optional:
  BOT_INDEX            Mnemonic derivation index for bot (default: 0, same as user)
  PERMIT2              Permit2 contract address (required for Permit2 flow)
  OUTPUT_TOKEN         Output token on destination (defaults to INPUT_TOKEN)
  FEE_RECIPIENT        Submission fee recipient (defaults to bot)
  SUBMISSION_FEE       Submission fee amount (defaults to 0)

Examples:

  # EIP-3009 flow:
  MNEMONIC="..." PERIPHERY=0x... SPOKE_POOL=0x... INPUT_TOKEN=0x... DESTINATION_CHAIN=1 \
  forge script script/GaslessHyperEVMDeposit.s.sol:GaslessHyperEVMDeposit \
    --sig "runERC3009(uint256,address,uint256)" 1000000 0xRecipient 995000 \
    --rpc-url hyperevm --broadcast -vvvv

  # Permit2 flow:
  MNEMONIC="..." PERIPHERY=0x... SPOKE_POOL=0x... INPUT_TOKEN=0x... PERMIT2=0x... DESTINATION_CHAIN=1 \
  forge script script/GaslessHyperEVMDeposit.s.sol:GaslessHyperEVMDeposit \
    --sig "runPermit2(uint256,address,uint256)" 1000000 0xRecipient 995000 \
    --rpc-url hyperevm --broadcast -vvvv

  # HL API sendAsset Core -> EVM (sends to system address, unified-account compatible):
  MNEMONIC="..." \
  forge script script/GaslessHyperEVMDeposit.s.sol:GaslessHyperEVMDeposit \
    --sig "submitHLSpotSend(string,uint256,uint8,uint64)" "USDC:0xeb62..." 10000000 6 0 \
    --rpc-url hyperevm -vvvv
*/
contract GaslessHyperEVMDeposit is Script {
    using AddressToBytes32 for address;

    // ─── Constants ───────────────────────────────────────────────────

    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    bytes32 constant BRIDGE_WITNESS_IDENTIFIER = keccak256("BridgeWitness");

    // Hyperliquid EIP-712 constants
    bytes32 constant HL_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant HL_SEND_ASSET_TYPEHASH =
        keccak256(
            "HyperliquidTransaction:SendAsset(string hyperliquidChain,string destination,string sourceDex,string destinationDex,string token,string amount,string fromSubAccount,uint64 nonce)"
        );

    // ─── Entry points ────────────────────────────────────────────────

    function run() external pure {
        revert("see header for supported run signatures");
    }

    /// @notice Test the EIP-3009 (receiveWithAuthorization) gasless deposit flow on HyperEVM.
    /// @dev The user signs a receiveWithAuthorization allowing the periphery to pull tokens.
    ///      The bot then submits the deposit transaction paying gas on the user's behalf.
    /// @param inputAmount Amount of input token (in token decimals).
    /// @param recipient Recipient address on the destination chain.
    /// @param outputAmount Expected output amount on the destination chain.
    function runERC3009(uint256 inputAmount, address recipient, uint256 outputAmount) external {
        // ─── Hardcoded HyperEVM addresses ────────────────────────────
        address periphery = 0x10D8b8DaA26d307489803e10477De69C0492B610;
        address spokePool = 0x35E63eA3eb0fb7A3bc543C71FB66412e1F6B0E04;
        address inputToken = 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC on HyperEVM
        address outputToken = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC on Arbitrum
        uint256 destinationChainId = 42161; // Arbitrum
        uint256 submissionFee = 0;

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 userPk = vm.deriveKey(mnemonic, 4);
        address user = vm.addr(userPk);
        uint256 botPk = vm.deriveKey(mnemonic, 0);
        address bot = vm.addr(botPk);

        // ─── Build deposit data ──────────────────────────────────────
        uint256 nonce = uint256(keccak256(abi.encodePacked(block.timestamp, user, block.number)));
        SpokePoolPeripheryInterface.DepositData memory depositData = SpokePoolPeripheryInterface.DepositData({
            submissionFees: SpokePoolPeripheryInterface.Fees({ amount: submissionFee, recipient: bot }),
            baseDepositData: SpokePoolPeripheryInterface.BaseDepositData({
                inputToken: inputToken,
                outputToken: outputToken.toBytes32(),
                outputAmount: outputAmount,
                depositor: user,
                recipient: recipient.toBytes32(),
                destinationChainId: destinationChainId,
                exclusiveRelayer: bytes32(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 6 hours),
                exclusivityParameter: 0,
                message: new bytes(0)
            }),
            inputAmount: inputAmount,
            spokePool: spokePool,
            nonce: nonce
        });

        // ─── Sign ────────────────────────────────────────────────────
        bytes32 witness = keccak256(abi.encodePacked(BRIDGE_WITNESS_IDENTIFIER, abi.encode(depositData)));
        uint256 validAfter = 0;
        uint256 validBefore = type(uint256).max;
        uint256 pullAmount = inputAmount + submissionFee;

        bytes32 tokenDomainSep = IERC712DomainSeparator(inputToken).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                user,
                periphery,
                pullAmount,
                validAfter,
                validBefore,
                witness
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tokenDomainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        bytes memory authSignature = abi.encodePacked(r, s, v);

        // ─── Log & submit ────────────────────────────────────────────
        console2.log("=== EIP-3009 Gasless Deposit ===");
        console2.log("User:             ", user);
        console2.log("Bot:              ", bot);
        console2.log("Periphery:        ", periphery);
        console2.log("Input token:      ", inputToken);
        console2.log("Input amount:     ", inputAmount);
        console2.log("Destination chain:", destinationChainId);
        console2.log("Witness:          ");
        console2.logBytes32(witness);

        vm.startBroadcast(botPk);
        SpokePoolPeripheryInterface(periphery).depositWithAuthorization(
            user,
            depositData,
            validAfter,
            validBefore,
            authSignature
        );
        vm.stopBroadcast();

        console2.log("EIP-3009 deposit submitted successfully");
    }

    /// @notice Step 1: User signs an infinite ERC-2612 permit approval, bot submits it on-chain.
    /// @dev Run this before runPermit. Only needed once per user/token pair.
    function submitPermitApproval() external {
        address periphery = 0x10D8b8DaA26d307489803e10477De69C0492B610;
        address inputToken = 0x111111a1a0667d36bD57c0A9f569b98057111111; // USDH on HyperEVM

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 userPk = vm.deriveKey(mnemonic, 4);
        address user = vm.addr(userPk);
        uint256 botPk = vm.deriveKey(mnemonic, 0);

        IERC712DomainSeparator token = IERC712DomainSeparator(inputToken);
        uint256 tokenNonce = token.nonces(user);
        uint256 deadline = type(uint256).max;

        bytes32 permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitTypehash, user, periphery, type(uint256).max, tokenNonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        console2.log("=== Submit Permit Approval ===");
        console2.log("User:      ", user);
        console2.log("Spender:   ", periphery);
        console2.log("Token:     ", inputToken);
        console2.log("Allowance:  infinite");

        // Bot submits the permit on-chain (user doesn't need gas).
        vm.startBroadcast(botPk);
        IERC20Permit(inputToken).permit(user, periphery, type(uint256).max, deadline, v, r, s);
        vm.stopBroadcast();

        console2.log("Permit approval submitted successfully");
    }

    /// @notice Step 2: Bot submits depositWithPermit (permit signature is empty since approval already exists).
    /// @dev Requires submitPermitApproval to have been called first.
    /// @param inputAmount Amount of input token (in token decimals).
    /// @param recipient Recipient address on the destination chain.
    /// @param outputAmount Expected output amount on the destination chain.
    function runPermit(uint256 inputAmount, address recipient, uint256 outputAmount) external {
        // ─── Hardcoded HyperEVM addresses ────────────────────────────
        address periphery = 0x10D8b8DaA26d307489803e10477De69C0492B610;
        address spokePool = 0x35E63eA3eb0fb7A3bc543C71FB66412e1F6B0E04;
        address inputToken = 0x111111a1a0667d36bD57c0A9f569b98057111111; // USDC on HyperEVM
        address outputToken = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC on Arbitrum
        uint256 destinationChainId = 42161; // Arbitrum
        uint256 submissionFee = 0;

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 userPk = vm.deriveKey(mnemonic, 4);
        address user = vm.addr(userPk);
        uint256 botPk = vm.deriveKey(mnemonic, 0);
        address bot = vm.addr(botPk);

        // ─── Build deposit data ──────────────────────────────────────
        uint256 nonce = SpokePoolPeripheryInterface(periphery).permitNonces(user);

        SpokePoolPeripheryInterface.DepositData memory depositData = SpokePoolPeripheryInterface.DepositData({
            submissionFees: SpokePoolPeripheryInterface.Fees({ amount: submissionFee, recipient: bot }),
            baseDepositData: SpokePoolPeripheryInterface.BaseDepositData({
                inputToken: inputToken,
                outputToken: outputToken.toBytes32(),
                outputAmount: outputAmount,
                depositor: user,
                recipient: recipient.toBytes32(),
                destinationChainId: destinationChainId,
                exclusiveRelayer: bytes32(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp + 6 hours),
                exclusivityParameter: 0,
                message: new bytes(0)
            }),
            inputAmount: inputAmount,
            spokePool: spokePool,
            nonce: nonce
        });

        // ─── Sign deposit data (periphery EIP-712) ──────────────────
        bytes memory depositDataSignature;
        {
            bytes32 peripheryDomainSep = IERC712DomainSeparator(periphery).domainSeparator();
            bytes32 depositHash = MemPeripheryHash.hashDepositData(depositData);
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", peripheryDomainSep, depositHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
            depositDataSignature = abi.encodePacked(r, s, v);
        }

        // ─── Log & submit ────────────────────────────────────────────
        console2.log("=== Permit Gasless Deposit ===");
        console2.log("User:             ", user);
        console2.log("Bot:              ", bot);
        console2.log("Periphery:        ", periphery);
        console2.log("Input token:      ", inputToken);
        console2.log("Input amount:     ", inputAmount);
        console2.log("Destination chain:", destinationChainId);
        console2.log("Permit nonce:     ", nonce);

        // Empty permit signature — approval already exists, try/catch in periphery handles this.
        bytes memory emptyPermitSig = new bytes(65);

        vm.startBroadcast(botPk);
        SpokePoolPeripheryInterface(periphery).depositWithPermit(
            user,
            depositData,
            0, // deadline (unused since permit sig is empty)
            emptyPermitSig,
            depositDataSignature
        );
        vm.stopBroadcast();

        console2.log("Permit deposit submitted successfully");
    }

    /// @notice Submit a Hyperliquid sendAsset action to transfer tokens from Core to HyperEVM.
    /// @dev Sends to the token's system address (0x20...00 + tokenIndex) which triggers a
    ///      Core→EVM bridge: the protocol mints ERC20 tokens to the sender on HyperEVM.
    ///      Compatible with unified accounts.
    /// @param hlToken HL token identifier (e.g. "USDC:0xeb62eee3685fc5c...").
    /// @param amountWei Amount in wei (e.g. 10e6 for 10 USDC). Converted to human-readable for HL API.
    /// @param decimals Token decimals (e.g. 6 for USDC).
    /// @param tokenIndex HyperCore token index (e.g. 0 for USDC). Used to derive the system address.
    function submitHLSpotSend(string calldata hlToken, uint256 amountWei, uint8 decimals, uint64 tokenIndex) external {
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 4);
        address user = vm.addr(pk);
        uint64 timestamp = uint64(block.timestamp * 1000);

        bool isMainnet = block.chainid == 999;
        string memory chain = isMainnet ? "Mainnet" : "Testnet";
        string memory sigChainId = "0x66eee";
        string memory apiUrl = isMainnet
            ? "https://api.hyperliquid.xyz/exchange"
            : "https://api.hyperliquid-testnet.xyz/exchange";

        // Convert wei to human-readable decimal string for HL API.
        string memory amount = _weiToDecimal(amountWei, decimals);

        // Derive the system address for Core→EVM bridge.
        // Format: first byte 0x20, remaining 19 bytes are token index in big-endian.
        // HYPE is special: 0x2222222222222222222222222222222222222222.
        address systemAddr = _hlSystemAddress(tokenIndex, isMainnet);
        string memory destination = vm.toString(systemAddr);

        // EIP-712 domain: HyperliquidSignTransaction v1, chainId always 421614.
        bytes32 hlDomainSeparator = keccak256(
            abi.encode(
                HL_DOMAIN_TYPEHASH,
                keccak256("HyperliquidSignTransaction"),
                keccak256("1"),
                uint256(421614),
                address(0)
            )
        );

        // sendAsset to system address triggers Core→EVM bridge.
        // Both sourceDex and destinationDex must be "spot".
        bytes32 structHash = keccak256(
            abi.encode(
                HL_SEND_ASSET_TYPEHASH,
                keccak256(bytes(chain)),
                keccak256(bytes(destination)),
                keccak256(bytes("spot")),
                keccak256(bytes("spot")),
                keccak256(bytes(hlToken)),
                keccak256(bytes(amount)),
                keccak256(bytes("")),
                timestamp
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hlDomainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        console2.log("=== Hyperliquid sendAsset (Core -> EVM) ===");
        console2.log("User:        ", user);
        console2.log("System addr: ", systemAddr);
        console2.log("Token:       ", hlToken);
        console2.log("Amount:      ", amount);
        console2.log("Timestamp:   ", timestamp);
        console2.log("API URL:     ", apiUrl);

        _submitHLRequest(apiUrl, destination, hlToken, amount, chain, sigChainId, timestamp, r, s, v);
    }

    // ─── Internal: HL API helpers ────────────────────────────────────

    function _submitHLRequest(
        string memory apiUrl,
        string memory user,
        string memory hlToken,
        string memory amount,
        string memory chain,
        string memory sigChainId,
        uint64 nonce,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) internal {
        string memory nonceStr = vm.toString(nonce);
        // Build sendAsset action (unified-account compatible).
        string memory action = string(
            abi.encodePacked(
                '{"type":"sendAsset","hyperliquidChain":"',
                chain,
                '","signatureChainId":"',
                sigChainId,
                '","destination":"',
                user,
                '","sourceDex":"spot","destinationDex":"spot","token":"',
                hlToken,
                '","amount":"',
                amount,
                '","fromSubAccount":"","nonce":',
                nonceStr,
                "}"
            )
        );
        string memory body = string(
            abi.encodePacked(
                '{"action":',
                action,
                ',"nonce":',
                nonceStr,
                ',"signature":{"r":"',
                vm.toString(r),
                '","s":"',
                vm.toString(s),
                '","v":',
                vm.toString(v),
                '},"vaultAddress":null}'
            )
        );

        console2.log("Request body:");
        console2.log(body);

        string[] memory cmd = new string[](9);
        cmd[0] = "curl";
        cmd[1] = "-s";
        cmd[2] = "-X";
        cmd[3] = "POST";
        cmd[4] = apiUrl;
        cmd[5] = "-H";
        cmd[6] = "Content-Type: application/json";
        cmd[7] = "-d";
        cmd[8] = body;

        bytes memory response = vm.ffi(cmd);
        console2.log("Response:", string(response));
    }

    /// @dev Derive the HyperCore system address for a token index.
    ///      Format: 0x20 as first byte, token index in the last bytes (big-endian).
    ///      HYPE uses a special address: 0x2222...2222.
    function _hlSystemAddress(uint64 tokenIndex, bool isMainnet) internal pure returns (address) {
        uint64 hypeIndex = isMainnet ? uint64(150) : uint64(1105);
        if (tokenIndex == hypeIndex) return 0x2222222222222222222222222222222222222222;
        return address(uint160(0x2000000000000000000000000000000000000000) + tokenIndex);
    }

    /// @dev Convert a wei amount to a human-readable decimal string (e.g. 10500000, 6 → "10.5").
    function _weiToDecimal(uint256 wei_, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 whole = wei_ / unit;
        uint256 frac = wei_ % unit;

        if (frac == 0) return _uintToStr(whole);

        // Build fractional part with leading zeros, then strip trailing zeros.
        bytes memory fracDigits = new bytes(decimals);
        for (uint8 i = 0; i < decimals; i++) {
            frac *= 10;
            fracDigits[i] = bytes1(uint8(0x30 + frac / unit));
            frac %= unit;
        }
        // Strip trailing zeros.
        uint256 len = decimals;
        while (len > 0 && fracDigits[len - 1] == "0") len--;

        bytes memory trimmed = new bytes(len);
        for (uint256 i = 0; i < len; i++) trimmed[i] = fracDigits[i];

        return string(abi.encodePacked(_uintToStr(whole), ".", trimmed));
    }

    function _uintToStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) {
            digits++;
            tmp /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            buf[--digits] = bytes1(uint8(0x30 + (v % 10)));
            v /= 10;
        }
        return string(buf);
    }
}
