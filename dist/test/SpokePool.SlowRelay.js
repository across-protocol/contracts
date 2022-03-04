"use strict";
var __createBinding =
  (this && this.__createBinding) ||
  (Object.create
    ? function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        Object.defineProperty(o, k2, {
          enumerable: true,
          get: function () {
            return m[k];
          },
        });
      }
    : function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        o[k2] = m[k];
      });
var __setModuleDefault =
  (this && this.__setModuleDefault) ||
  (Object.create
    ? function (o, v) {
        Object.defineProperty(o, "default", { enumerable: true, value: v });
      }
    : function (o, v) {
        o["default"] = v;
      });
var __importStar =
  (this && this.__importStar) ||
  function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null)
      for (var k in mod)
        if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
  };
Object.defineProperty(exports, "__esModule", { value: true });
const utils_1 = require("./utils");
const SpokePool_Fixture_1 = require("./fixtures/SpokePool.Fixture");
const SpokePool_Fixture_2 = require("./fixtures/SpokePool.Fixture");
const MerkleLib_utils_1 = require("./MerkleLib.utils");
const consts = __importStar(require("./constants"));
let spokePool, weth, erc20, destErc20;
let depositor, recipient, relayer;
let relays;
let tree;
const fullRelayAmountPostFees = consts.amountToRelay
  .mul(consts.totalPostFeesPct)
  .div((0, utils_1.toBN)(consts.oneHundredPct));
describe("SpokePool Slow Relay Logic", async function () {
  beforeEach(async function () {
    [depositor, recipient, relayer] = await utils_1.ethers.getSigners();
    ({ weth, erc20, spokePool, destErc20 } = await (0, SpokePool_Fixture_1.spokePoolFixture)());
    // mint some fresh tokens and deposit ETH for weth for depositor and relayer.
    await (0, utils_1.seedWallet)(depositor, [erc20], weth, consts.amountToSeedWallets);
    await (0, utils_1.seedWallet)(depositor, [destErc20], weth, consts.amountToSeedWallets);
    await (0, utils_1.seedWallet)(relayer, [erc20], weth, consts.amountToSeedWallets);
    await (0, utils_1.seedWallet)(relayer, [destErc20], weth, consts.amountToSeedWallets);
    // Send tokens to the spoke pool for repayment.
    await destErc20.connect(depositor).transfer(spokePool.address, fullRelayAmountPostFees);
    await weth.connect(depositor).transfer(spokePool.address, fullRelayAmountPostFees);
    // Approve spoke pool to take relayer's tokens.
    await destErc20.connect(relayer).approve(spokePool.address, fullRelayAmountPostFees);
    await weth.connect(relayer).approve(spokePool.address, fullRelayAmountPostFees);
    // Whitelist origin token => destination chain ID routes:
    await (0,
    SpokePool_Fixture_1.enableRoutes)(spokePool, [{ originToken: erc20.address }, { originToken: weth.address }]);
    relays = [];
    for (let i = 0; i < 99; i++) {
      relays.push({
        depositor: (0, utils_1.randomAddress)(),
        recipient: (0, utils_1.randomAddress)(),
        destinationToken: (0, utils_1.randomAddress)(),
        amount: (0, utils_1.randomBigNumber)().toString(),
        originChainId: (0, utils_1.randomBigNumber)(2).toString(),
        realizedLpFeePct: (0, utils_1.randomBigNumber)(8).toString(),
        relayerFeePct: (0, utils_1.randomBigNumber)(8).toString(),
        depositId: (0, utils_1.randomBigNumber)(2).toString(),
      });
    }
    // ERC20
    relays.push({
      depositor: depositor.address,
      recipient: recipient.address,
      destinationToken: destErc20.address,
      amount: consts.amountToRelay.toString(),
      originChainId: consts.originChainId.toString(),
      realizedLpFeePct: consts.realizedLpFeePct.toString(),
      relayerFeePct: consts.depositRelayerFeePct.toString(),
      depositId: consts.firstDepositId.toString(),
    });
    // WETH
    relays.push({
      depositor: depositor.address,
      recipient: recipient.address,
      destinationToken: weth.address,
      amount: consts.amountToRelay.toString(),
      originChainId: consts.originChainId.toString(),
      realizedLpFeePct: consts.realizedLpFeePct.toString(),
      relayerFeePct: consts.depositRelayerFeePct.toString(),
      depositId: consts.firstDepositId.toString(),
    });
    tree = await (0, MerkleLib_utils_1.buildSlowRelayTree)(relays);
    await spokePool.connect(depositor).relayRootBundle(consts.mockTreeRoot, tree.getHexRoot());
  });
  it("Simple SlowRelay ERC20 balances", async function () {
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address))
          )
        )
    ).to.changeTokenBalances(
      destErc20,
      [spokePool, recipient],
      [fullRelayAmountPostFees.mul(-1), fullRelayAmountPostFees]
    );
  });
  // TODO: Move to Optimism_SpokePool test.
  // it("Execute root wraps any ETH owned by contract", async function () {
  //   const amountOfEthToWrap = toWei("1");
  //   await relayer.sendTransaction({
  //     to: spokePool.address,
  //     value: amountOfEthToWrap,
  //   });
  //   // Pool should have wrapped all ETH
  //   await expect(() =>
  //     spokePool
  //       .connect(relayer)
  //       .executeSlowRelayRoot(
  //         ...getExecuteSlowRelayParams(
  //           depositor.address,
  //           recipient.address,
  //           weth.address,
  //           consts.amountToRelay,
  //           consts.originChainId,
  //           consts.realizedLpFeePct,
  //           consts.depositRelayerFeePct,
  //           consts.firstDepositId,
  //           0,
  //           tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address)!)
  //         )
  //       )
  //   ).to.changeEtherBalance(spokePool, amountOfEthToWrap.mul(-1));
  // });
  it("Simple SlowRelay ERC20 event", async function () {
    const relay = relays.find((relay) => relay.destinationToken === destErc20.address);
    await (0, utils_1.expect)(
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address))
          )
        )
    )
      .to.emit(spokePool, "ExecutedSlowRelayRoot")
      .withArgs(
        tree.hashFn(relay),
        consts.amountToRelay,
        consts.amountToRelay,
        consts.amountToRelay,
        consts.originChainId,
        consts.depositRelayerFeePct,
        consts.realizedLpFeePct,
        consts.firstDepositId,
        destErc20.address,
        relayer.address,
        depositor.address,
        recipient.address
      );
  });
  it("Simple SlowRelay WETH balance", async function () {
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address))
          )
        )
    ).to.changeTokenBalances(weth, [spokePool], [fullRelayAmountPostFees.mul(-1)]);
  });
  it("Simple SlowRelay ETH balance", async function () {
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address))
          )
        )
    ).to.changeEtherBalance(recipient, fullRelayAmountPostFees);
  });
  it("Partial SlowRelay ERC20 balances", async function () {
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPostFees = fullRelayAmountPostFees.sub(partialAmountPostFees);
    await spokePool
      .connect(relayer)
      .fillRelay(
        ...(0, SpokePool_Fixture_2.getFillRelayParams)(
          (0, SpokePool_Fixture_2.getRelayHash)(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            destErc20.address,
            consts.amountToRelay.toString()
          ).relayData,
          partialAmountPostFees
        )
      );
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            destErc20.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === destErc20.address))
          )
        )
    ).to.changeTokenBalances(destErc20, [spokePool, recipient], [leftoverPostFees.mul(-1), leftoverPostFees]);
  });
  it("Partial SlowRelay WETH balance", async function () {
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPostFees = fullRelayAmountPostFees.sub(partialAmountPostFees);
    await spokePool
      .connect(relayer)
      .fillRelay(
        ...(0, SpokePool_Fixture_2.getFillRelayParams)(
          (0, SpokePool_Fixture_2.getRelayHash)(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            weth.address,
            consts.amountToRelay.toString()
          ).relayData,
          partialAmountPostFees
        )
      );
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address))
          )
        )
    ).to.changeTokenBalances(weth, [spokePool], [leftoverPostFees.mul(-1)]);
  });
  it("Partial SlowRelay ETH balance", async function () {
    const partialAmountPostFees = fullRelayAmountPostFees.div(4);
    const leftoverPostFees = fullRelayAmountPostFees.sub(partialAmountPostFees);
    await spokePool
      .connect(relayer)
      .fillRelay(
        ...(0, SpokePool_Fixture_2.getFillRelayParams)(
          (0, SpokePool_Fixture_2.getRelayHash)(
            depositor.address,
            recipient.address,
            consts.firstDepositId,
            consts.originChainId,
            weth.address,
            consts.amountToRelay.toString()
          ).relayData,
          partialAmountPostFees
        )
      );
    await (0, utils_1.expect)(() =>
      spokePool
        .connect(relayer)
        .executeSlowRelayRoot(
          ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
            depositor.address,
            recipient.address,
            weth.address,
            consts.amountToRelay,
            consts.originChainId,
            consts.realizedLpFeePct,
            consts.depositRelayerFeePct,
            consts.firstDepositId,
            0,
            tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address))
          )
        )
    ).to.changeEtherBalance(recipient, leftoverPostFees);
  });
  it("Bad proof", async function () {
    await (0, utils_1.expect)(
      spokePool.connect(relayer).executeSlowRelayRoot(
        ...(0, SpokePool_Fixture_1.getExecuteSlowRelayParams)(
          depositor.address,
          recipient.address,
          weth.address,
          consts.amountToRelay.sub(1), // Slightly modify the relay data from the expected set.
          consts.originChainId,
          consts.realizedLpFeePct,
          consts.depositRelayerFeePct,
          consts.firstDepositId,
          0,
          tree.getHexProof(relays.find((relay) => relay.destinationToken === weth.address))
        )
      )
    ).to.be.reverted;
  });
});
