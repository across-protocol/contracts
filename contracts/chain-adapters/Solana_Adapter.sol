// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMessageTransmitter, ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";
import { AdapterInterface } from "./interfaces/AdapterInterface.sol";
import { CircleCCTPAdapter, CircleDomainIds } from "../libraries/CircleCCTPAdapter.sol";
import { Bytes32ToAddress } from "../libraries/AddressConverters.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Solana via CCTP.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore it's only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 * @custom:security-contact bugs@across.to
 */

// solhint-disable-next-line contract-name-camelcase
contract Solana_Adapter is AdapterInterface, CircleCCTPAdapter {
    /**
     * @notice We use Bytes32ToAddress library to map a Solana address to an Ethereum address representation.
     * @dev The Ethereum address is derived from the Solana address by truncating it to its lowest 20 bytes. This same
     * conversion must be done by the HubPool owner when adding Solana spoke pool and setting the corresponding pool
     * rebalance and deposit routes.
     */
    using Bytes32ToAddress for bytes32;

    /**
     * @notice The official Circle CCTP MessageTransmitter contract endpoint.
     * @dev Posted officially here: https://developers.circle.com/stablecoins/docs/evm-smart-contracts
     */
    // solhint-disable-next-line immutable-vars-naming
    IMessageTransmitter public immutable cctpMessageTransmitter;

    // Solana spoke pool address, decoded from Base58 to bytes32.
    bytes32 public immutable SOLANA_SPOKE_POOL_BYTES32;

    // Solana spoke pool address, mapped to its EVM address representation.
    address public immutable SOLANA_SPOKE_POOL_ADDRESS;

    // USDC mint address on Solana, mapped to its EVM address representation.
    address public immutable SOLANA_USDC_ADDRESS;

    // USDC token address on Solana for the spoke pool (vault ATA), decoded from Base58 to bytes32.
    bytes32 public immutable SOLANA_SPOKE_POOL_USDC_VAULT;

    // Custom errors for constructor argument validation.
    error InvalidCctpTokenMessenger(address tokenMessenger);
    error InvalidCctpMessageTransmitter(address messageTransmitter);

    // Custom errors for relayMessage validation.
    error InvalidRelayMessageTarget(address target);

    // Custom errors for relayTokens validation.
    error InvalidL1Token(address l1Token);
    error InvalidL2Token(address l2Token);
    error InvalidAmount(uint256 amount);
    error InvalidTokenRecipient(address to);

    /**
     * @notice Constructs new Adapter.
     * @param _l1Usdc USDC address on L1.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge tokens via CCTP.
     * @param _cctpMessageTransmitter MessageTransmitter contract to bridge messages via CCTP.
     * @param solanaSpokePool Solana spoke pool address, decoded from Base58 to bytes32.
     * @param solanaUsdc USDC mint address on Solana, decoded from Base58 to bytes32.
     * @param solanaSpokePoolUsdcVault USDC token address on Solana for the spoke pool, decoded from Base58 to bytes32.
     */
    constructor(
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger,
        IMessageTransmitter _cctpMessageTransmitter,
        bytes32 solanaSpokePool,
        bytes32 solanaUsdc,
        bytes32 solanaSpokePoolUsdcVault
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, CircleDomainIds.Solana) {
        // Solana adapter requires CCTP TokenMessenger and MessageTransmitter contracts to be set.
        if (address(_cctpTokenMessenger) == address(0)) {
            revert InvalidCctpTokenMessenger(address(_cctpTokenMessenger));
        }
        if (address(_cctpMessageTransmitter) == address(0)) {
            revert InvalidCctpMessageTransmitter(address(_cctpMessageTransmitter));
        }

        cctpMessageTransmitter = _cctpMessageTransmitter;

        SOLANA_SPOKE_POOL_BYTES32 = solanaSpokePool;
        SOLANA_SPOKE_POOL_ADDRESS = solanaSpokePool.toAddressUnchecked();

        SOLANA_USDC_ADDRESS = solanaUsdc.toAddressUnchecked();

        SOLANA_SPOKE_POOL_USDC_VAULT = solanaSpokePoolUsdcVault;
    }

    /**
     * @notice Send cross-chain message to target on Solana.
     * @dev Only allows sending messages to the Solana spoke pool.
     * @param target Program on Solana (translated as EVM address) that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        if (target != SOLANA_SPOKE_POOL_ADDRESS) {
            revert InvalidRelayMessageTarget(target);
        }
        cctpMessageTransmitter.sendMessage(CircleDomainIds.Solana, SOLANA_SPOKE_POOL_BYTES32, message);

        // TODO: consider if we need also to emit the translated message.
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Solana.
     * @dev Only allows bridging USDC to Solana spoke pool.
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
        if (l1Token != address(usdcToken)) {
            revert InvalidL1Token(l1Token);
        }
        if (l2Token != SOLANA_USDC_ADDRESS) {
            revert InvalidL2Token(l2Token);
        }
        if (amount > type(uint64).max) {
            revert InvalidAmount(amount);
        }
        if (to != SOLANA_SPOKE_POOL_ADDRESS) {
            revert InvalidTokenRecipient(to);
        }

        _transferUsdc(SOLANA_SPOKE_POOL_USDC_VAULT, amount);

        // TODO: consider if we need also to emit the translated addresses.
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
