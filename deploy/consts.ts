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
  42: {
    optimismCrossDomainMessenger: "0x4361d0F75A0186C05f971c566dC6bEa5957483fD",
    weth: "0xd0A1E359811322d97991E03f863a0C30C2cF029C",
    optimismStandardBridge: "0x22F24361D548e5FaAfb36d1437839f080363982B",
    finder: "0xeD0169a88d267063184b0853BaAAAe66c3c154B2",
  },
};
