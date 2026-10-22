// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Merkle } from "murky/Merkle.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { HyperCoreWithdrawImplementation } from "../../contracts/periphery/counterfactual/HyperCoreWithdrawImplementation.sol";
import { WithdrawParams } from "../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { CounterfactualBeaconBase } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBase.sol";
import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";

/**
 * @notice Builds the full transaction sequence to recover a **HyperCore spot balance** stranded at a v3
 *         counterfactual deposit address (funds sent to the address Core-side, unreachable by any leaf in
 *         its creation-time route tree). It authorizes ONE new leaf — `HyperCoreWithdrawImplementation`
 *         with the same `WithdrawParams(admin, user)` as the existing withdraw leaf — for this ONE proxy,
 *         via the beacon's upgrade tree. Recipient is pinned to the creation-time refund address; nothing
 *         in the sequence can redirect funds.
 *
 *         Incident: counterfactual_deposit_address id 1083070, 3,848.240373 USDC spot-sent to the deposit
 *         address on HyperCore (2026-07-19 / 2026-07-21, Intercom 215475222911726).
 *
 * How to run (read-only; prints calldata, broadcasts nothing):
 *   forge script script/counterfactual/RecoverHyperCoreSpotBalance.s.sol:RecoverHyperCoreSpotBalance \
 *     --rpc-url $NODE_URL_999 -vvvv
 *
 * Output is four transactions, in order:
 *   1. beacon.setUpgradeRoot(upgradeRoot)      — beacon owner (Safe)
 *   2. factory.deploy(salt, initialRoot)       — anyone (deploys the proxy at the deposit address)
 *   3. proxy.updateRoot(newRoot, [])           — anyone
 *   4. manager.directWithdraw(...)             — directWithdrawer (Safe)
 * Steps 1+4 can be batched with 2+3 into a single Safe MultiSend (order preserved).
 * After broadcast, verify the Core-side transfer landed (CoreWriter actions fail silently):
 * the deposit address's HyperCore USDC spot balance must be 0 and the user's credited.
 */
contract RecoverHyperCoreSpotBalance is DeploymentUtils {
    // --- Canonical counterfactual v3 stack on HyperEVM (chain 999), verified live 2026-07-25 ---
    address constant FACTORY = 0x9F62dcc4B939485911C4f9b24BdCa4324D6b97d1;
    address constant BEACON = 0xB7eBaD46Ae4Ccbd0d9676ee1A34Ceb0136388133;
    address constant ADMIN_WITHDRAW_MANAGER = 0xa8cD6EDDa01d394434Dc0cb1A7958a0223374689;

    // --- Incident data: counterfactual_deposit_address id 1083070 ---
    address constant DEPOSIT_ADDRESS = 0xACDe1Bc40B4DF760FB388DA503ee6a99794E2cb6;
    address constant USER = 0xfae1d8C606A26071A01B59F3F02e157083114B90; // recipient AND refund address
    bytes32 constant SALT = 0x017b00000000000000000000000000000000000000000000000000000000010b;
    bytes32 constant INITIAL_ROOT = 0xecfb05ceee3461857e6a4e53f6681ae7cc4e52aeb8160b8554c2de3beb0eed1f;
    address constant EVM_WITHDRAW_IMPL = 0x4eCffb4A23e26aE937Bd9185969c8bb71073fBb9;

    // USDC on HyperCore: index 0 → asset-bridge address 0x2000…0000; wei decimals 8.
    address constant USDC_BRIDGE = 0x2000000000000000000000000000000000000000;
    // Full stranded balance: 3,848.240373 USDC = 384_824_037_300 Core wei. Static — no other party can
    // debit the account. Re-verify against the HL API (spotClearinghouseState) before broadcasting.
    uint256 constant AMOUNT_CORE = 384_824_037_300;

    /// @dev The 7 creation-time route-tree leaf hashes, from `counterfactualMaterialsV3` (id 1083070):
    ///      vanilla-cctp, sponsored-cctp, 2x spokepool-usdc, 2x spokepool-usdt, withdraw.
    function _existingLeaves() internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](7);
        leaves[0] = 0xcfc30f5953ef862bf306e6db703626600dcdc9a2750b2606d0b84fea9a9cb329;
        leaves[1] = 0x89cfce39be080cc0221f3ab35485509b8cdc3e0e4a1bc4db92cd42640c8fd1a4;
        leaves[2] = 0x3e9627ffb1ccf528385e3130123aa1a53f8623bb1deec249a766a91f011564fc;
        leaves[3] = 0xe23f711007fab1939099331939099b9c3eeaf5836afd0f3b76153ff466a47a52;
        leaves[4] = 0x69bb1049a57b9b3336d9ee49e2b6b98ccb0562765a03a105428e84b17a15f0b9;
        leaves[5] = 0x030fc29427195ece3ef08ca39f25cf88cc5bd206971bc3f591675f2daca62058;
        leaves[6] = 0x18c49958fdc17284ba5be31e811319b16c74ae37fcf55b22507132dce2e4e1c6; // withdraw
    }

    function _leaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
    }

    function run() external {
        // The new leaf reuses the existing withdraw leaf's params: admin = AdminWithdrawManager,
        // user = the creation-pinned refund address.
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: ADMIN_WITHDRAW_MANAGER, user: USER }));

        // Sanity: our params encoding must reproduce the creation-time withdraw leaf exactly.
        require(
            _leaf(EVM_WITHDRAW_IMPL, withdrawParams) == _existingLeaves()[6],
            "withdraw leaf mismatch vs creation materials"
        );

        // Resolve the HyperCoreWithdrawImplementation address (CREATE2, salt 0 — deploy with
        // DeployHyperCoreWithdrawImplementation.s.sol first, or let this predict it).
        address coreImpl = vm.envOr("HYPERCORE_WITHDRAW_IMPL", address(0));
        if (coreImpl == address(0)) {
            coreImpl = _predictCreate2(bytes32(0), type(HyperCoreWithdrawImplementation).creationCode);
        }

        // New route tree = the 7 creation-time leaves + the HyperCore withdraw leaf.
        bytes32[] memory leaves = new bytes32[](8);
        bytes32[] memory existing = _existingLeaves();
        for (uint256 i = 0; i < 7; i++) leaves[i] = existing[i];
        leaves[7] = _leaf(coreImpl, withdrawParams);

        Merkle merkle = new Merkle();
        bytes32 newRoot = merkle.getRoot(leaves);
        bytes32[] memory coreLeafProof = merkle.getProof(leaves, 7);
        require(MerkleProof.verify(coreLeafProof, newRoot, leaves[7]), "core leaf proof invalid");

        // Upgrade tree: a single (proxy, newRoot) leaf — root IS the leaf, proof is empty.
        bytes32 upgradeRoot = keccak256(bytes.concat(keccak256(abi.encode(DEPOSIT_ADDRESS, newRoot))));
        bytes32[] memory emptyProof = new bytes32[](0);
        require(MerkleProof.verify(emptyProof, upgradeRoot, upgradeRoot), "upgrade tree invalid");

        // Live checks when pointed at HyperEVM.
        if (block.chainid == 999) {
            require(
                CounterfactualDepositFactory(FACTORY).predictAddress(SALT, INITIAL_ROOT) == DEPOSIT_ADDRESS,
                "predictAddress mismatch"
            );
            console.log("Live check OK: factory.predictAddress(salt, initialRoot) == deposit address");
        }

        console.log("HyperCoreWithdrawImplementation:", coreImpl);
        console.log("New route root / upgrade root:");
        console.logBytes32(newRoot);
        console.logBytes32(upgradeRoot);

        console.log("\n--- tx 1 (beacon owner Safe): beacon.setUpgradeRoot ---");
        console.log("to:", BEACON);
        console.logBytes(abi.encodeCall(CounterfactualBeaconBase.setUpgradeRoot, (upgradeRoot)));

        console.log("\n--- tx 2 (anyone): factory.deploy ---");
        console.log("to:", FACTORY);
        console.logBytes(abi.encodeCall(CounterfactualDepositFactory.deploy, (SALT, INITIAL_ROOT)));

        console.log("\n--- tx 3 (anyone): proxy.updateRoot ---");
        console.log("to:", DEPOSIT_ADDRESS);
        console.logBytes(abi.encodeCall(CounterfactualDeposit.updateRoot, (newRoot, emptyProof)));

        console.log("\n--- tx 4 (directWithdrawer Safe): manager.directWithdraw ---");
        console.log("to:", ADMIN_WITHDRAW_MANAGER);
        console.logBytes(
            abi.encodeCall(
                AdminWithdrawManager.directWithdraw,
                (DEPOSIT_ADDRESS, coreImpl, withdrawParams, abi.encode(USDC_BRIDGE, USER, AMOUNT_CORE), coreLeafProof)
            )
        );
    }
}
