// Source: // https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts/deployments
// Note that L2 optimism addresses are deterministic and constant, so they usually don't need an
// address map like this.
export const L1_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  1: {
    optimismCrossDomainMessenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1",
    weth: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    optimismStandardBridge: "0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1",
    finder: "0x40f941E48A552bF496B154Af6bf55725f18D77c3",
    polygonRootChainManager: "0xA0c68C638235ee32657e8f720a23ceC1bFc77C77",
    polygonFxRoot: "0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2",
  },
  4: {
    weth: "0xc778417E063141139Fce010982780140Aa0cD5Ab",
    finder: "0xbb6206fb01fAad31e8aaFc3AD303cEA89D8c8157",
    l1ArbitrumInbox: "0x578BAde599406A8fE3d24Fd7f7211c0911F5B29e", // Should be listed as "DelayedInbox" here: https://developer.offchainlabs.com/docs/useful_addresses
    l1ERC20GatewayRouter: "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380", // Should be listed as "L1 ERC20 Gateway Router" here: https://developer.offchainlabs.com/docs/useful_addresses
    optimismCrossDomainMessenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1", // dummy: Optimism's testnet is kovan
    optimismStandardBridge: "0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1", // dummy: Optimism's testnet is kovan
    polygonRootChainManager: "0xBbD7cBFA79faee899Eaf900F13C9065bF03B1A74", // dummy: Polygon's testnet is goerli
    polygonFxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA", // dummy: Polygon's testnet is goerli
  },
  5: {
    optimismCrossDomainMessenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1", // dummy: Optimism's testnet is kovan
    optimismStandardBridge: "0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1", // dummy: Optimism's testnet is kovan
    l1ArbitrumInbox: "0x578BAde599406A8fE3d24Fd7f7211c0911F5B29e", // dummy: Arbitrum's testnet is rinkeby
    l1ERC20GatewayRouter: "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380", // dummy: Arbitrum's testnet is rinkeby
    finder: "0xDC6b80D38004F495861E081e249213836a2F3217",
    polygonRootChainManager: "0xBbD7cBFA79faee899Eaf900F13C9065bF03B1A74",
    polygonFxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA",
    weth: "0x60D4dB9b534EF9260a88b0BED6c486fe13E604Fc",
  },
  42: {
    l1ArbitrumInbox: "0x578BAde599406A8fE3d24Fd7f7211c0911F5B29e", // dummy: Arbitrum's testnet is rinkeby
    l1ERC20GatewayRouter: "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380", // dummy: Arbitrum's testnet is rinkeby
    optimismCrossDomainMessenger: "0x4361d0F75A0186C05f971c566dC6bEa5957483fD",
    weth: "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
    optimismStandardBridge: "0x22F24361D548e5FaAfb36d1437839f080363982B",
    finder: "0xeD0169a88d267063184b0853BaAAAe66c3c154B2",
    polygonRootChainManager: "0xBbD7cBFA79faee899Eaf900F13C9065bF03B1A74", // dummy: Polygon's testnet is goerli
    polygonFxRoot: "0x3d1d3E34f7fB6D26245E6640E1c50710eFFf15bA", // dummy: Polygon's testnet is goerli
  },
};

export const L2_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  421611: {
    l2GatewayRouter: "0x9413AD42910c1eA60c737dB5f58d1C504498a3cD",
    l2Weth: "0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681",
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
};

export const POLYGON_CHAIN_IDS: { [l1ChainId: number]: number } = {
  1: 137,
  5: 80001,
};
