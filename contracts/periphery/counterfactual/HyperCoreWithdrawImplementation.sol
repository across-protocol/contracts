// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { HyperCoreLib } from "../../libraries/HyperCoreLib.sol";
import { WithdrawParams } from "./WithdrawImplementation.sol";

/**
 * @title HyperCoreWithdrawImplementation
 * @notice Recovers funds sitting in a counterfactual's **HyperCore spot balance** — e.g. a Core-side spot
 *         Send made directly to the deposit address, which never touches an EVM chain and is therefore
 *         unreachable by `WithdrawImplementation` (the clone's Core account can only be debited by the
 *         clone itself, via a CoreWriter action). Sends the requested amount to the leaf-committed `user`
 *         on HyperCore. HyperEVM only — the CoreWriter/precompile addresses exist on no other chain.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher, so the CoreWriter action is
 *      credited against the clone's own Core account. `params` and `submitterData` mirror
 *      `WithdrawImplementation` — `WithdrawParams(admin, user)` and `(address token, address to,
 *      uint256 amount)` — so both `AdminWithdrawManager` paths (`directWithdraw`,
 *      `signedWithdrawToUser`) work unchanged. Differences:
 *      - `token` is the HyperCore **asset-bridge address** of the Core token
 *        (`0x2000…0000 + coreIndex`; USDC = `0x2000…0000`), not an ERC-20. Addresses below the bridge
 *        range revert (checked underflow in `toTokenId`).
 *      - `amount` is in Core wei units (must fit uint64).
 *      - the Core recipient is ALWAYS the committed `user`; the `to` field is ignored.
 *      NOTE: CoreWriter actions are enqueued, not executed, by the EVM tx — a Core-side failure (bad
 *      token index, insufficient spot balance, non-existent recipient account) is silent and leaves the
 *      funds in place. Verify the Core-side transfer landed before treating a withdrawal as done.
 * @custom:security-contact bugs@across.to
 */
contract HyperCoreWithdrawImplementation is ICounterfactualImplementation {
    event CoreWithdraw(uint64 indexed coreToken, address indexed to, uint64 amountCore);

    error Unauthorized();

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Recovery mechanism for Core-side balances — no bridging. `params` is ABI-encoded as
     *      `WithdrawParams` (admin, user); `submitterData` as `(address token, address to, uint256 amount)`.
     *      Reverts: `Unauthorized` (caller is not admin or user), arithmetic panic (`token` below the
     *      asset-bridge range), `SafeCast` overflow (`amount` exceeds uint64).
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        WithdrawParams memory wp = abi.decode(params, (WithdrawParams));
        (address token, , uint256 amount) = abi.decode(submitterData, (address, address, uint256));

        if (msg.sender != wp.admin && msg.sender != wp.user) revert Unauthorized();

        uint64 coreToken = HyperCoreLib.toTokenId(token);
        uint64 amountCore = SafeCast.toUint64(amount);
        HyperCoreLib.transferERC20SpotToSpot(coreToken, wp.user, amountCore);

        emit CoreWithdraw(coreToken, wp.user, amountCore);
    }
}
