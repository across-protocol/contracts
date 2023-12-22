export const L1_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  1: {
    optimismCrossDomainMessenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1", // Source: https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts/deployments
    optimismStandardBridge: "0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1",
    bobaCrossDomainMessenger: "0x6D4528d192dB72E282265D6092F4B872f9Dff69e",
    bobaStandardBridge: "0xdc1664458d2f0B6090bEa60A8793A4E66c2F1c00",
    weth: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    finder: "0x40f941E48A552bF496B154Af6bf55725f18D77c3",
    l1ArbitrumInbox: "0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f",
    l1ERC20GatewayRouter: "0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef",
    polygonRootChainManager: "0xA0c68C638235ee32657e8f720a23ceC1bFc77C77",
    polygonFxRoot: "0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2",
    polygonERC20Predicate: "0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf",
    polygonRegistry: "0x33a02E6cC863D393d6Bf231B697b82F6e499cA71",
    polygonDepositManager: "0x401F6c983eA34274ec46f84D70b31C151321188b",
    matic: "0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0",
    l2WrappedMatic: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
    baseCrossDomainMessenger: "0x866E82a600A1414e583f7F13623F1aC5d58b0Afa",
    baseStandardBridge: "0x3154Cf16ccdb4C6d922629664174b904d80F2C35",
    scrollERC20GatewayRouter: "0xF8B1378579659D8F7EE5f3C929c2f3E332E41Fd6",
    scrollMessengerRelay: "0x6774Bcbd5ceCeF1336b5300fb5186a12DDD8b367",
  },
  4: {
    weth: "0xc778417E063141139Fce010982780140Aa0cD5Ab",
    finder: "0xbb6206fb01fAad31e8aaFc3AD303cEA89D8c8157",
    l1ArbitrumInbox: "0x578BAde599406A8fE3d24Fd7f7211c0911F5B29e", // Should be listed as "DelayedInbox" here: https://developer.offchainlabs.com/docs/useful_addresses
    l1ERC20GatewayRouter: "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380", // Should be listed as "L1 ERC20 Gateway Router" here: https://developer.offchainlabs.com/docs/useful_addresses
    polygonRootChainManager: "0xBbD7cBFA79faee899Eaf900F13C9065bF03B1A74", // Dummy: Polygon's testnet is goerli
    polygonFxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA", // Dummy: Polygon's testnet is goerli
    polygonERC20Predicate: "0xdD6596F2029e6233DEFfaCa316e6A95217d4Dc34", // Dummy: Polygon's testnet is goerli
    polygonRegistry: "0xeE11713Fe713b2BfF2942452517483654078154D", // Dummy: Polygon's testnet is goerli
    polygonDepositManager: "0x7850ec290A2e2F40B82Ed962eaf30591bb5f5C96", // Dummy: Polygon's testnet is goerli
    matic: "0x499d11E0b6eAC7c0593d8Fb292DCBbF815Fb29Ae", // Dummy: Polygon's testnet is goerli
    l2WrappedMatic: "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889", // Dummy: Polygon's testnet is goerli
  },
  5: {
    optimismCrossDomainMessenger: "0x5086d1eEF304eb5284A0f6720f79403b4e9bE294",
    weth: "0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6",
    optimismStandardBridge: "0x636Af16bf2f682dD3109e60102b8E1A089FedAa8",
    l1ArbitrumInbox: "0x6BEbC4925716945D46F0Ec336D5C2564F419682C",
    l1ERC20GatewayRouter: "0x4c7708168395aEa569453Fc36862D2ffcDaC588c",
    finder: "0xDC6b80D38004F495861E081e249213836a2F3217",
    polygonRootChainManager: "0xBbD7cBFA79faee899Eaf900F13C9065bF03B1A74",
    polygonFxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA",
    polygonERC20Predicate: "0xdD6596F2029e6233DEFfaCa316e6A95217d4Dc34",
    polygonRegistry: "0xeE11713Fe713b2BfF2942452517483654078154D",
    polygonDepositManager: "0x7850ec290A2e2F40B82Ed962eaf30591bb5f5C96",
    matic: "0x499d11E0b6eAC7c0593d8Fb292DCBbF815Fb29Ae",
    l2WrappedMatic: "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889",
    baseCrossDomainMessenger: "0x8e5693140eA606bcEB98761d9beB1BC87383706D",
    baseStandardBridge: "0xfA6D8Ee5BE770F84FC001D098C4bD604Fe01284a",
  },
  42: {
    l1ArbitrumInbox: "0x578BAde599406A8fE3d24Fd7f7211c0911F5B29e", // dummy: Arbitrum's testnet is rinkeby
    l1ERC20GatewayRouter: "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380", // dummy: Arbitrum's testnet is rinkeby
    optimismCrossDomainMessenger: "0x4361d0F75A0186C05f971c566dC6bEa5957483fD",
    weth: "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
    optimismStandardBridge: "0x22F24361D548e5FaAfb36d1437839f080363982B",
    finder: "0xeD0169a88d267063184b0853BaAAAe66c3c154B2",
    polygonRootChainManager: "0xBbD7cBFA79faee899Eaf900F13C9065bF03B1A74", // Dummy: Polygon's testnet is goerli
    polygonFxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA", // Dummy: Polygon's testnet is goerli
    polygonERC20Predicate: "0xdD6596F2029e6233DEFfaCa316e6A95217d4Dc34", // Dummy: Polygon's testnet is goerli
    polygonRegistry: "0xeE11713Fe713b2BfF2942452517483654078154D", // Dummy: Polygon's testnet is goerli
    polygonDepositManager: "0x7850ec290A2e2F40B82Ed962eaf30591bb5f5C96", // Dummy: Polygon's testnet is goerli
    matic: "0x499d11E0b6eAC7c0593d8Fb292DCBbF815Fb29Ae", // Dummy: Polygon's testnet is goerli
    l2WrappedMatic: "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889", // Dummy: Polygon's testnet is goerli
  },
  280: {
    weth: "0x20b28B1e4665FFf290650586ad76E977EAb90c5D",
  },
  324: {
    weth: "0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91",
  },
  11155111: {
    finder: "0xeF684C38F94F48775959ECf2012D7E864ffb9dd4",
    weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    scrollERC20GatewayRouter: "0x13FBE0D0e5552b8c9c4AE9e2435F38f37355998a",
    scrollMessengerRelay: "0x50c7d3e7f7c656493D1D76aaa1a836CedfCBB16A",
    scrollGasPriceOracle: "0x247969F4fad93a33d4826046bc3eAE0D36BdE548",
  },
};

export const L2_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  421611: {
    l2GatewayRouter: "0x9413AD42910c1eA60c737dB5f58d1C504498a3cD",
    l2Weth: "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681",
  },
  421613: {
    l2GatewayRouter: "0xE5B9d8d42d656d1DcB8065A6c012FE3780246041",
    l2Weth: "0xe39Ab88f8A4777030A534146A9Ca3B52bd5D43A3",
  },
  42161: {
    l2GatewayRouter: "0x5288c571Fd7aD117beA99bF60FE0846C4E84F933",
    l2Weth: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
  },
  137: {
    wMatic: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
    fxChild: "0x8397259c983751DAf40400790063935a11afa28a",
  },
  80001: {
    wMatic: "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889",
    fxChild: "0xCf73231F28B7331BBe3124B907840A94851f9f11",
  },
  280: {
    l2Weth: "0x20b28B1e4665FFf290650586ad76E977EAb90c5D",
    zkErc20Bridge: "0x00ff932A6d70E2B8f1Eb4919e1e09C1923E7e57b",
  },
  324: {
    l2Weth: "0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91",
    zkErc20Bridge: "0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102",
  },
  534351: {
    l2Weth: "0x5300000000000000000000000000000000000004",
    scrollERC20GatewayRouter: "0x9aD3c5617eCAa556d6E166787A97081907171230",
    scrollGasPriceOracle: "0x5300000000000000000000000000000000000002",
  },
};

export const POLYGON_CHAIN_IDS: { [l1ChainId: number]: number } = {
  1: 137,
  5: 80001,
};
