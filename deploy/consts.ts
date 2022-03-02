// Source: // https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts/deployments
// Note that L2 optimism addresses are deterministic and constant, so they usually don't need an
// address map like this.
export const L1_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  1: {
    optimismCrossDomainMessenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1",
    weth: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    optimismStandardBridge: "0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1",
    finder: "0x40f941E48A552bF496B154Af6bf55725f18D77c3",
  },
  4: {
    weth: "0xc778417E063141139Fce010982780140Aa0cD5Ab",
    finder: "0xbb6206fb01fAad31e8aaFc3AD303cEA89D8c8157",
    l1ArbitrumInbox: "0x578BAde599406A8fE3d24Fd7f7211c0911F5B29e",
    l1ERC20Gateway: "0x91169Dbb45e6804743F94609De50D511C437572E",
  },
  42: {
    optimismCrossDomainMessenger: "0x4361d0F75A0186C05f971c566dC6bEa5957483fD",
    weth: "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
    optimismStandardBridge: "0x22F24361D548e5FaAfb36d1437839f080363982B",
    finder: "0xeD0169a88d267063184b0853BaAAAe66c3c154B2",
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
};
