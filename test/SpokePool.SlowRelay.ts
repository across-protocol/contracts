import {
  expect,
  Contract,
  ethers,
  SignerWithAddress,
  seedWallet,
  toBN,
  randomAddress,
  randomBigNumber,
  getParamType,
  defaultAbiCoder,
  keccak256,
} from "./utils";
import { spokePoolFixture, enableRoutes, RelayData } from "./SpokePool.Fixture";
import { MerkleTree } from "../utils/MerkleTree";
import * as consts from "./constants";

let spokePool: Contract, weth: Contract, erc20: Contract, destErc20: Contract;
let depositor: SignerWithAddress, recipient: SignerWithAddress, relayer: SignerWithAddress;
let relays: RelayData[];
let tree: MerkleTree<RelayData>;

const fullRelayAmountPostFees = consts.amountToRelay.mul(consts.totalPostFeesPct).div(toBN(consts.oneHundredPct));

describe("SpokePool Slow Relay Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await spokePoolFixture());

    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await seedWallet(depositor, [erc20], weth, consts.amountToSeedWallets);
    await seedWallet(depositor, [destErc20], weth, consts.amountToSeedWallets);
    await seedWallet(relayer, [erc20], weth, consts.amountToSeedWallets);
    await seedWallet(relayer, [destErc20], weth, consts.amountToSeedWallets);

    // Send tokens to the spoke pool for repayment.
    await destErc20.connect(depositor).transfer(spokePool.address, fullRelayAmountPostFees);
    await weth.connect(depositor).transfer(spokePool.address, fullRelayAmountPostFees);

    // Approve spoke pool to take relayer's tokens.
    await destErc20.connect(relayer).approve(spokePool.address, fullRelayAmountPostFees);
    await weth.connect(relayer).approve(spokePool.address, fullRelayAmountPostFees);

    // Whitelist origin token => destination chain ID routes:
    await enableRoutes(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);

    relays = [];
    for (let i = 0; i < 99; i++) {
      relays.push({
        depositor: randomAddress(),
        recipient: randomAddress(),
        destinationToken: randomAddress(),
        relayAmount: randomBigNumber().toString(),
        realizedLpFeePct: randomBigNumber(8).toString(),
        relayerFeePct: randomBigNumber(8).toString(),
        depositId: randomBigNumber(2).toString(),
        originChainId: randomBigNumber(2).toString(),
      });
    }

    // ERC20
    relays.push({
      depositor: depositor.address,
      recipient: recipient.address,
      destinationToken: destErc20.address,
      relayAmount: consts.amountToRelay.toString(),
      realizedLpFeePct: consts.realizedLpFeePct.toString(),
      relayerFeePct: consts.depositRelayerFeePct.toString(),
      depositId: consts.firstDepositId.toString(),
      originChainId: consts.originChainId.toString(),
    });

    // WETH
    relays.push({
      depositor: depositor.address,
      recipient: recipient.address,
      destinationToken: weth.address,
      relayAmount: consts.amountToRelay.toString(),
      realizedLpFeePct: consts.realizedLpFeePct.toString(),
      relayerFeePct: consts.depositRelayerFeePct.toString(),
      depositId: consts.firstDepositId.toString(),
      originChainId: consts.originChainId.toString(),
    });

    const paramType = await getParamType("MerkleLib", "verifySlowRelayFulfillment", "slowRelayFulfillment");
    const hashFn = (input: RelayData) => {
      return keccak256(defaultAbiCoder.encode([paramType!], [input]));
    };
    tree = new MerkleTree(relays, hashFn);

    await spokePool.connect(depositor).initializeRelayerRefund(consts.mockTreeRoot, tree.getHexRoot());
  });
  it("Simple SlowRelay ERC20 balances", async function () {
    await expect(() =>
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          destErc20.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address)!)
        )
    ).to.changeTokenBalances(
      destErc20,
      [spokePool, recipient],
      [fullRelayAmountPostFees.mul(-1), fullRelayAmountPostFees]
    );
  });

  it("Simple SlowRelay ERC20 event", async function () {
    const relay = relays.find((relay) => relay.destinationToken === destErc20.address)!;

    await expect(
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          destErc20.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address)!)
        )
    )
      .to.emit(spokePool, "DistributeRelaySlow")
      .withArgs(
        tree.hashFn(relay),
        consts.amountToRelay,
        consts.amountToRelay,
        consts.amountToRelay,
        consts.depositRelayerFeePct,
        consts.realizedLpFeePct,
        consts.originChainId,
        consts.firstDepositId,
        destErc20.address,
        relayer.address,
        depositor.address,
        recipient.address
      );
  });

  it("Simple SlowRelay WETH balance", async function () {
    await expect(() =>
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
        )
    ).to.changeTokenBalances(weth, [spokePool], [fullRelayAmountPostFees.mul(-1)]);
  });

  it("Simple SlowRelay ETH balance", async function () {
    await expect(() =>
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
        )
    ).to.changeEtherBalance(recipient, fullRelayAmountPostFees);
  });

  it("Simple SlowRelay WETH event", async function () {
    const relay = relays.find((relay) => relay.destinationToken === weth.address)!;

    await expect(
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
        )
    )
      .to.emit(spokePool, "DistributeRelaySlow")
      .withArgs(
        tree.hashFn(relay),
        consts.amountToRelay,
        consts.amountToRelay,
        consts.amountToRelay,
        consts.depositRelayerFeePct,
        consts.realizedLpFeePct,
        consts.originChainId,
        consts.firstDepositId,
        weth.address,
        relayer.address,
        depositor.address,
        recipient.address
      );
  });

  it("Partial SlowRelay ERC20 balances", async function () {
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPostFees = fullRelayAmountPostFees.sub(partialAmountPostFees);

    await spokePool
      .connect(relayer)
      .fillRelay(
        depositor.address,
        recipient.address,
        destErc20.address,
        consts.amountToRelay,
        partialAmountPostFees,
        consts.realizedLpFeePct,
        consts.depositRelayerFeePct,
        consts.repaymentChainId,
        consts.firstDepositId,
        consts.originChainId
      );
    await expect(() =>
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          destErc20.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address)!)
        )
    ).to.changeTokenBalances(destErc20, [spokePool, recipient], [leftoverPostFees.mul(-1), leftoverPostFees]);
  });

  it("Partial SlowRelay ERC20 event", async function () {
    const relay = relays.find((relay) => relay.destinationToken === destErc20.address)!;
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPreFees = consts.amountToRelay.mul(3).div(4);

    await spokePool
      .connect(relayer)
      .fillRelay(
        depositor.address,
        recipient.address,
        destErc20.address,
        consts.amountToRelay,
        partialAmountPostFees,
        consts.realizedLpFeePct,
        consts.depositRelayerFeePct,
        consts.repaymentChainId,
        consts.firstDepositId,
        consts.originChainId
      );

    await expect(
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          destErc20.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address)!)
        )
    )
      .to.emit(spokePool, "DistributeRelaySlow")
      .withArgs(
        tree.hashFn(relay),
        consts.amountToRelay,
        consts.amountToRelay,
        leftoverPreFees,
        consts.depositRelayerFeePct,
        consts.realizedLpFeePct,
        consts.originChainId,
        consts.firstDepositId,
        destErc20.address,
        relayer.address,
        depositor.address,
        recipient.address
      );
  });

  it("Partial SlowRelay WETH balance", async function () {
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPostFees = fullRelayAmountPostFees.sub(partialAmountPostFees);

    await spokePool
      .connect(relayer)
      .fillRelay(
        depositor.address,
        recipient.address,
        weth.address,
        consts.amountToRelay,
        partialAmountPostFees,
        consts.realizedLpFeePct,
        consts.depositRelayerFeePct,
        consts.repaymentChainId,
        consts.firstDepositId,
        consts.originChainId
      );

    await expect(() =>
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
        )
    ).to.changeTokenBalances(weth, [spokePool], [leftoverPostFees.mul(-1)]);
  });

  it("Partial SlowRelay ETH balance", async function () {
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPostFees = fullRelayAmountPostFees.sub(partialAmountPostFees);

    await spokePool
      .connect(relayer)
      .fillRelay(
        depositor.address,
        recipient.address,
        weth.address,
        consts.amountToRelay,
        partialAmountPostFees,
        consts.realizedLpFeePct,
        consts.depositRelayerFeePct,
        consts.repaymentChainId,
        consts.firstDepositId,
        consts.originChainId
      );

    await expect(() =>
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
        )
    ).to.changeEtherBalance(recipient, leftoverPostFees);
  });

  it("Partial SlowRelay WETH event", async function () {
    const relay = relays.find((relay) => relay.destinationToken === weth.address)!;
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPreFees = consts.amountToRelay.mul(3).div(4);

    await spokePool
      .connect(relayer)
      .fillRelay(
        depositor.address,
        recipient.address,
        weth.address,
        consts.amountToRelay,
        partialAmountPostFees,
        consts.realizedLpFeePct,
        consts.depositRelayerFeePct,
        consts.repaymentChainId,
        consts.firstDepositId,
        consts.originChainId
      );

    await expect(
      spokePool
        .connect(relayer)
        .distributeRelaySlow(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          consts.originChainId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
        )
    )
      .to.emit(spokePool, "DistributeRelaySlow")
      .withArgs(
        tree.hashFn(relay),
        consts.amountToRelay,
        consts.amountToRelay,
        leftoverPreFees,
        consts.depositRelayerFeePct,
        consts.realizedLpFeePct,
        consts.originChainId,
        consts.firstDepositId,
        weth.address,
        relayer.address,
        depositor.address,
        recipient.address
      );
  });

  it("Bad proof", async function () {
    await expect(
      spokePool.connect(relayer).distributeRelaySlow(
        depositor.address,
        recipient.address,
        weth.address,
        consts.amountToRelay.sub(1), // Slightly modify the relay data from the expected set.
        consts.realizedLpFeePct,
        consts.depositRelayerFeePct,
        consts.firstDepositId,
        consts.originChainId,
        0,
        tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
      )
    ).to.be.reverted;
  });
});
