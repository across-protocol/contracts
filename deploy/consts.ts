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
    l1BlastBridge: "0x3a05E5d33d7Ab3864D53aaEc93c8301C1Fa49115",
    blastCrossDomainMessenger: "0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0",
    blastStandardBridge: "0x697402166Fbf2F22E970df8a6486Ef171dbfc524",
    l1Usdb: "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    dai: "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    cctpTokenMessenger: "0xBd3fa81B58Ba92a82136038B25aDec7066af3155",
    cctpMessageTransmitter: "0x0a992d191deec32afe36203ad87d7d289a738f81",
    lineaMessageService: "0xd19d4B5d358258f05D7B411E21A1460D11B0876F",
    lineaTokenBridge: "0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319",
    lineaUsdcBridge: "0x504a330327a089d8364c4ab3811ee26976d388ce",
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    scrollERC20GatewayRouter: "0xF8B1378579659D8F7EE5f3C929c2f3E332E41Fd6",
    scrollMessengerRelay: "0x6774Bcbd5ceCeF1336b5300fb5186a12DDD8b367",
    scrollGasPriceOracle: "0x0d7E906BD9cAFa154b048cFa766Cc1E54E39AF9B",
    modeCrossDomainMessenger: "0x95bDCA6c8EdEB69C98Bd5bd17660BaCef1298A6f",
    modeStandardBridge: "0x735aDBbE72226BD52e818E7181953f42E3b0FF21",
    liskCrossDomainMessenger: "0x31B72D76FB666844C41EdF08dF0254875Dbb7edB",
    liskStandardBridge: "0x2658723Bf70c7667De6B25F99fcce13A16D25d08",
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
    cctpTokenMessenger: "0xD0C3da58f55358142b8d3e06C1C30c5C6114EFE8",
    cctpMessageTransmitter: "0x26413e8157cd32011e726065a5462e97dd4d03d9",
    lineaMessageService: "0x70BaD09280FD342D02fe64119779BC1f0791BAC2",
    lineaTokenBridge: "0x5506A3805fB8A58Fa58248CC52d2b06D92cA94e6",
    lineaUsdcBridge: "0x32D123756d32d3eD6580935f8edF416e57b940f4",
    polygonZkEvmBridge: "0xF6BEEeBB578e214CA9E23B0e9683454Ff88Ed2A7",
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
    optimismCrossDomainMessenger: "0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef",
    optimismStandardBridge: "0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1",
    bobaCrossDomainMessenger: "0x6D4528d192dB72E282265D6092F4B872f9Dff69e", // No sepolia deploy address
    bobaStandardBridge: "0xdc1664458d2f0B6090bEa60A8793A4E66c2F1c00", // No sepolia deploy address
    finder: "0xeF684C38F94F48775959ECf2012D7E864ffb9dd4",
    weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    l1ArbitrumInbox: "0xaAe29B0366299461418F5324a79Afc425BE5ae21",
    l1ERC20GatewayRouter: "0xcE18836b233C83325Cc8848CA4487e94C6288264",
    baseCrossDomainMessenger: "0xC34855F4De64F1840e5686e64278da901e261f20",
    baseStandardBridge: "0xfd0Bf71F60660E2f608ed56e1659C450eB113120",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    lineaMessageService: "0xd19d4B5d358258f05D7B411E21A1460D11B0876F", // No sepolia deploy address
    lineaTokenBridge: "0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319", // No sepolia deploy address
    lineaUsdcBridge: "0x504a330327a089d8364c4ab3811ee26976d388ce", // No sepolia deploy address
    scrollERC20GatewayRouter: "0x13FBE0D0e5552b8c9c4AE9e2435F38f37355998a",
    scrollMessengerRelay: "0x50c7d3e7f7c656493D1D76aaa1a836CedfCBB16A",
    scrollGasPriceOracle: "0x247969F4fad93a33d4826046bc3eAE0D36BdE548",
    modeCrossDomainMessenger: "0xc19a60d9E8C27B9A43527c3283B4dd8eDC8bE15C",
    modeStandardBridge: "0xbC5C679879B2965296756CD959C3C739769995E2",

    // https://github.com/maticnetwork/static/blob/master/network/testnet/amoy/index.json
    polygonRootChainManager: "0x34F5A25B627f50Bb3f5cAb72807c4D4F405a9232",
    polygonFxRoot: "0x0E13EBEdDb8cf9f5987512d5E081FdC2F5b0991e",
    polygonERC20Predicate: "0x4258C75b752c812B7Fa586bdeb259f2d4bd17f4F",
    polygonRegistry: "0xfE92F7c3a701e43d8479738c8844bCc555b9e5CD",
    polygonDepositManager: "0x44Ad17990F9128C6d823Ee10dB7F0A5d40a731A4",
    matic: "0x3fd0A53F4Bf853985a95F4Eb3F9C9FDE1F8e2b53",
    l2WrappedMatic: "0x360ad4f9a9A8EFe9A8DCB5f461c4Cc1047E1Dcf9",

    // https://docs.lisk.com/contracts
    liskCrossDomainMessenger: "0x857824E6234f7733ecA4e9A76804fd1afa1A3A2C",
    liskStandardBridge: "0x1Fb30e446eA791cd1f011675E5F3f5311b70faF5",

    // https://docs.blast.io/building/contracts
    l1BlastBridge: "0xc644cc19d2A9388b71dd1dEde07cFFC73237Dca8",
    blastCrossDomainMessenger: "0x9338F298F29D3918D5D1Feb209aeB9915CC96333",
    blastStandardBridge: "0xDeDa8D3CCf044fE2A16217846B6e1f1cfD8e122f",
    l1Usdb: "0x7f11f79DEA8CE904ed0249a23930f2e59b43a385",
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
    l2Usdc: "0xfd064A18f3BF249cf1f87FC203E90D8f650f2d63",
    cctpTokenMessenger: "0x12dcfd3fe2e9eac2859fd1ed86d2ab8c5a2f9352",
    cctpMessageTransmitter: "0x109bc137cb64eab7c0b1dddd1edf341467dc2d35",
  },
  421614: {
    l2GatewayRouter: "0x9fDD1C4E4AA24EEc1d913FABea925594a20d43C7",
    l2Weth: "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73",
    l2Usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0xaCF1ceeF35caAc005e15888dDb8A3515C41B4872",
  },
  42161: {
    l2GatewayRouter: "0x5288c571Fd7aD117beA99bF60FE0846C4E84F933",
    l2Weth: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
    l2Usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    cctpTokenMessenger: "0x19330d10D9Cc8751218eaf51E8885D058642E08A",
    cctpMessageTransmitter: "0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca",
    uniswapV3SwapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
  },
  137: {
    wMatic: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
    fxChild: "0x8397259c983751DAf40400790063935a11afa28a",
    l2Usdc: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
    cctpTokenMessenger: "0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE",
    cctpMessageTransmitter: "0xF3be9355363857F3e001be68856A2f96b4C39Ba9",
    uniswapV3SwapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
  },
  80001: {
    wMatic: "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889",
    fxChild: "0xCf73231F28B7331BBe3124B907840A94851f9f11",
    l2Usdc: "0x9999f7Fea5938fD3b1E26A12c3f2fb024e194f97",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0xe09A679F56207EF33F5b9d8fb4499Ec00792eA73",
  },
  80002: {
    wMatic: "0x360ad4f9a9A8EFe9A8DCB5f461c4Cc1047E1Dcf9",
    fxChild: "0xE5930336866d0388f0f745A2d9207C7781047C0f",
    l2Usdc: "0x41e94eb019c0762f9bfcf9fb1e58725bfb0e7582",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
  },
  280: {
    l2Weth: "0x20b28B1e4665FFf290650586ad76E977EAb90c5D",
    zkErc20Bridge: "0x00ff932A6d70E2B8f1Eb4919e1e09C1923E7e57b",
  },
  324: {
    l2Weth: "0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91",
    zkErc20Bridge: "0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102",
    "1inchV6Router": "0x6fd4383cB451173D5f9304F041C7BCBf27d561fF",
  },
  10: {
    l2Usdc: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
    cctpTokenMessenger: "0x2B4069517957735bE00ceE0fadAE88a26365528f",
    cctpMessageTransmitter: "0x4d41f22c5a0e5c74090899e5a8fb597a8842b3e8",
    uniswapV3SwapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
  },
  420: {
    l2Usdc: "0xe05606174bac4A6364B31bd0eCA4bf4dD368f8C6",
    cctpTokenMessenger: "0x23a04d5935ed8bc8e3eb78db3541f0abfb001c6e",
    cctpMessageTransmitter: "0x9ff9a4da6f2157a9c82ce756f8fd7e0d75be8895",
  },
  11155420: {
    l2Usdc: "0x5fd84259d66Cd46123540766Be93DFE6D43130D7",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
    uniswapV3SwapRouter: "0xd8866E76441df243fc98B892362Fc6264dC3ca80", // Mock_UniswapV3SwapRouter.sol
  },
  81457: {
    usdb: "0x4300000000000000000000000000000000000003",
  },
  8453: {
    l2Usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    cctpTokenMessenger: "0x1682Ae6375C4E4A97e4B583BC394c861A46D8962",
    cctpMessageTransmitter: "0xAD09780d193884d503182aD4588450C416D6F9D4",
    uniswapV3SwapRouter: "0x2626664c2603336E57B271c5C0b26F421741e481",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
  },
  84531: {
    l2Usdc: "0xf175520c52418dfe19c8098071a252da48cd1c19",
    cctpTokenMessenger: "0x877b8e8c9e2383077809787ED6F279ce01CB4cc8",
    cctpMessageTransmitter: "0x9ff9a4da6f2157A9c82CE756f8fD7E0d75be8895",
  },
  84532: {
    l2Usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
    uniswapV3SwapRouter: "0x7945814de23d76dfff0cfc6ecb76456b9f7ac648", // Mock_UniswapV3SwapRouter.sol
  },
  59144: {
    l2Weth: "0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f",
    lineaMessageService: "0x508Ca82Df566dCD1B0DE8296e70a96332cD644ec",
    lineaUsdcBridge: "0xA2Ee6Fce4ACB62D95448729cDb781e3BEb62504A",
    lineaTokenBridge: "0x353012dc4a9A6cF55c941bADC267f82004A8ceB9",
  },
  59140: {
    l2Weth: "0x2C1b868d6596a18e32E61B901E4060C872647b6C",
    lineaMessageService: "0xC499a572640B64eA1C8c194c43Bc3E19940719dC",
    lineaUsdcBridge: "0xDFa112375c9be9D124932b1d104b73f888655329",
    lineaTokenBridge: "0x3ccd0F623B7a25Eab5dFc6a3fD723dCE5520489B",
  },
  534351: {
    l2Weth: "0x5300000000000000000000000000000000000004",
    scrollERC20GatewayRouter: "0x9aD3c5617eCAa556d6E166787A97081907171230",
    scrollGasPriceOracle: "0x5300000000000000000000000000000000000002",
    scrollMessenger: "0xba50f5340fb9f3bd074bd638c9be13ecb36e603d",
  },
  534352: {
    l2Weth: "0x5300000000000000000000000000000000000004",
    scrollERC20GatewayRouter: "0x4C0926FF5252A435FD19e10ED15e5a249Ba19d79",
    scrollGasPriceOracle: "0x5300000000000000000000000000000000000002",
    scrollMessenger: "0x781e90f1c8Fc4611c9b7497C3B47F99Ef6969CbC",
  },
  1442: {
    // Custom WETH for testing because there is no "official" WETH
    l2Weth: "0x3ab6C7AEb93A1CFC64AEEa8BF0f00c176EE42A2C",
    polygonZkEvmBridge: "0xF6BEEeBB578e214CA9E23B0e9683454Ff88Ed2A7",
  },
  919: {
    l2Weth: "0x4200000000000000000000000000000000000006",
  },
  34443: {
    l2Weth: "0x4200000000000000000000000000000000000006",
  },
  168587773: {
    usdb: "0x4200000000000000000000000000000000000022",
  },
};

export const POLYGON_CHAIN_IDS: { [l1ChainId: number]: number } = {
  1: 137,
  5: 80001,
  11155111: 80002,
};

/**
 * The domain ID provided by Circle for each supported chain ID.
 * @note This is not the same as the chain ID.
 * @note Only reference by the mainnet token, they are all the same.
 * @link https://developers.circle.com/stablecoins/docs/supported-domains
 */
export const CIRCLE_DOMAIN_IDs: { [chainId: number]: number } = {
  1: 0, // Mainnet
  10: 2, // Optimism
  42161: 3, // Arbitrum
  8453: 6, // Base
  137: 7, // Polygon
  // testnets
  5: 0, // Goerli
  11155111: 0, // Eth Sepolia
  420: 2, // Optimism Goerli
  421613: 3, // Arbitrum Goerli
  84531: 6, // Base Goerli
  80001: 7, // Polygon Goerli
  80002: 7, // Polygon Amoy
};
