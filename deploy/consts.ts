import { ZERO_ADDRESS } from "@uma/common";
import { CHAIN_IDs, PUBLIC_NETWORKS, TOKEN_SYMBOLS_MAP } from "../utils";

export { ZERO_ADDRESS } from "@uma/common";

export const USDC = TOKEN_SYMBOLS_MAP.USDC.addresses;
export const USDCe = TOKEN_SYMBOLS_MAP["USDC.e"].addresses;
export const WETH = TOKEN_SYMBOLS_MAP.WETH.addresses;
export const WMATIC = TOKEN_SYMBOLS_MAP.WMATIC.addresses;
export const WAZERO = TOKEN_SYMBOLS_MAP.WAZERO.addresses;
export const AZERO = TOKEN_SYMBOLS_MAP.AZERO;
export const WGRASS = TOKEN_SYMBOLS_MAP.WGRASS.addresses;
export const WGHO = TOKEN_SYMBOLS_MAP.WGHO.addresses;

export const QUOTE_TIME_BUFFER = 3600;
export const FILL_DEADLINE_BUFFER = 6 * 3600;
export const ARBITRUM_MAX_SUBMISSION_COST = "10000000000000000";
export const AZERO_GAS_PRICE = "240000000000";
export const CIRCLE_UNINITIALIZED_DOMAIN_ID = 4294967295; // 2^32 - 1

export const ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT = 800;
export const ZK_L2_GAS_LIMIT = 2000000;
export const ZK_MAX_GASPRICE = "10000000000000"; // 10k gwei

export const L1_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  [CHAIN_IDs.MAINNET]: {
    finder: "0x40f941E48A552bF496B154Af6bf55725f18D77c3",
    l1ArbitrumInbox: "0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f",
    l1ERC20GatewayRouter: "0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef",
    polygonRootChainManager: "0xA0c68C638235ee32657e8f720a23ceC1bFc77C77",
    polygonFxRoot: "0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2",
    polygonERC20Predicate: "0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf",
    polygonRegistry: "0x33a02E6cC863D393d6Bf231B697b82F6e499cA71",
    polygonDepositManager: "0x401F6c983eA34274ec46f84D70b31C151321188b",
    cctpTokenMessenger: "0xBd3fa81B58Ba92a82136038B25aDec7066af3155",
    cctpV2TokenMessenger: "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d",
    cctpMessageTransmitter: "0x0a992d191deec32afe36203ad87d7d289a738f81",
    lineaMessageService: "0xd19d4B5d358258f05D7B411E21A1460D11B0876F",
    lineaTokenBridge: "0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319",
    scrollERC20GatewayRouter: "0xF8B1378579659D8F7EE5f3C929c2f3E332E41Fd6",
    scrollMessengerRelay: "0x6774Bcbd5ceCeF1336b5300fb5186a12DDD8b367",
    scrollGasPriceOracle: "0x56971da63A3C0205184FEF096E9ddFc7A8C2D18a",
    blastYieldManager: "0xa230285d5683C74935aD14c446e137c8c8828438",
    blastDaiRetriever: "0x98Dd57048d7d5337e92D9102743528ea4Fea64aB",
    l1AlephZeroInbox: "0x56D8EC76a421063e1907503aDd3794c395256AEb",
    l1AlephZeroERC20GatewayRouter: "0xeBb17f398ed30d02F2e8733e7c1e5cf566e17812",
    donationBox: "0x0d57392895Db5aF3280e9223323e20F3951E81B1",
    adapterStore: "0x42df4D71f35ffBD28ae217d52E83C1DA0007D63b",
    hubPoolStore: "0x1Ace3BbD69b63063F859514Eca29C9BDd8310E61",
    zkBridgeHub: "0x303a465B659cBB0ab36eE643eA362c509EEb5213",
    zkUsdcSharedBridge_232: "0xf553E6D903AA43420ED7e3bc2313bE9286A8F987",
    zkUsdcSharedBridge_324: "0xD7f9f54194C633F36CCD5F3da84ad4a1c38cB2cB", // This is the standard shared bridge contract.
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.SEPOLIA]: {
    finder: "0xeF684C38F94F48775959ECf2012D7E864ffb9dd4",
    l1ArbitrumInbox: "0xaAe29B0366299461418F5324a79Afc425BE5ae21",
    l1ERC20GatewayRouter: "0xcE18836b233C83325Cc8848CA4487e94C6288264",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
    usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    lineaMessageService: "0xd19d4B5d358258f05D7B411E21A1460D11B0876F", // No sepolia deploy address
    lineaTokenBridge: "0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319", // No sepolia deploy address
    scrollERC20GatewayRouter: "0x13FBE0D0e5552b8c9c4AE9e2435F38f37355998a",
    scrollMessengerRelay: "0x50c7d3e7f7c656493D1D76aaa1a836CedfCBB16A",
    scrollGasPriceOracle: "0x247969F4fad93a33d4826046bc3eAE0D36BdE548",
    donationBox: "0x74f00724075443Cbbf55129F17CbAB0F77bA0722",

    // https://github.com/maticnetwork/static/blob/master/network/testnet/amoy/index.json
    polygonRootChainManager: "0x34F5A25B627f50Bb3f5cAb72807c4D4F405a9232",
    polygonFxRoot: "0x0E13EBEdDb8cf9f5987512d5E081FdC2F5b0991e",
    polygonERC20Predicate: "0x4258C75b752c812B7Fa586bdeb259f2d4bd17f4F",
    polygonRegistry: "0xfE92F7c3a701e43d8479738c8844bCc555b9e5CD",
    polygonDepositManager: "0x44Ad17990F9128C6d823Ee10dB7F0A5d40a731A4",
    zkBridgeHub: "0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
};

export const OP_STACK_ADDRESS_MAP: {
  [hubChainId: number]: {
    [spokeChainId: number]: { [contract: string]: string };
  };
} = {
  [CHAIN_IDs.MAINNET]: {
    [CHAIN_IDs.BASE]: {
      L1CrossDomainMessenger: "0x866E82a600A1414e583f7F13623F1aC5d58b0Afa",
      L1StandardBridge: "0x3154Cf16ccdb4C6d922629664174b904d80F2C35",
    },
    [CHAIN_IDs.BOBA]: {
      L1CrossDomainMessenger: "0x6D4528d192dB72E282265D6092F4B872f9Dff69e",
      L1StandardBridge: "0xdc1664458d2f0B6090bEa60A8793A4E66c2F1c00",
    },
    [CHAIN_IDs.BLAST]: {
      L1BlastBridge: "0x3a05E5d33d7Ab3864D53aaEc93c8301C1Fa49115",
      L1CrossDomainMessenger: "0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0",
      L1StandardBridge: "0x697402166Fbf2F22E970df8a6486Ef171dbfc524",
    },
    [CHAIN_IDs.UNICHAIN]: {
      L1CrossDomainMessenger: "0x9A3D64E386C18Cb1d6d5179a9596A4B5736e98A6",
      L1StandardBridge: "0x81014F44b0a345033bB2b3B21C7a1A308B35fEeA",
    },
    [CHAIN_IDs.INK]: {
      L1CrossDomainMessenger: "0x69d3cf86b2bf1a9e99875b7e2d9b6a84426c171f",
      L1StandardBridge: "0x88ff1e5b602916615391f55854588efcbb7663f0",
      L1OpUSDCBridgeAdapter: ZERO_ADDRESS,
    },
    [CHAIN_IDs.LISK]: {
      L1CrossDomainMessenger: "0x31B72D76FB666844C41EdF08dF0254875Dbb7edB",
      L1StandardBridge: "0x2658723Bf70c7667De6B25F99fcce13A16D25d08",
      L1OpUSDCBridgeAdapter: "0xE3622468Ea7dD804702B56ca2a4f88C0936995e6",
    },
    [CHAIN_IDs.MODE]: {
      L1CrossDomainMessenger: "0x95bDCA6c8EdEB69C98Bd5bd17660BaCef1298A6f",
      L1StandardBridge: "0x735aDBbE72226BD52e818E7181953f42E3b0FF21",
    },
    [CHAIN_IDs.OPTIMISM]: {
      L1CrossDomainMessenger: "0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1", // Source: https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts/deployments
      L1StandardBridge: "0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1",
    },
    [CHAIN_IDs.REDSTONE]: {
      L1CrossDomainMessenger: "0x592C1299e0F8331D81A28C0FC7352Da24eDB444a",
      L1StandardBridge: "0xc473ca7E02af24c129c2eEf51F2aDf0411c1Df69",
    },
    [CHAIN_IDs.SONEIUM]: {
      L1CrossDomainMessenger: "0x9cf951e3f74b644e621b36ca9cea147a78d4c39f",
      L1StandardBridge: "0xeb9bf100225c214efc3e7c651ebbadcf85177607",
      L1OpUSDCBridgeAdapter: "0xC67A8c5f22b40274Ca7C4A56Db89569Ee2AD3FAb",
    },
    [CHAIN_IDs.WORLD_CHAIN]: {
      L1CrossDomainMessenger: "0xf931a81D18B1766d15695ffc7c1920a62b7e710a",
      L1StandardBridge: "0x470458C91978D2d929704489Ad730DC3E3001113",
      L1OpUSDCBridgeAdapter: "0x153A69e4bb6fEDBbAaF463CB982416316c84B2dB",
    },
    [CHAIN_IDs.ZORA]: {
      L1CrossDomainMessenger: "0xdC40a14d9abd6F410226f1E6de71aE03441ca506",
      L1StandardBridge: "0x3e2Ea9B92B7E48A52296fD261dc26fd995284631",
    },
  },
  [CHAIN_IDs.SEPOLIA]: {
    [CHAIN_IDs.BASE_SEPOLIA]: {
      L1CrossDomainMessenger: "0xC34855F4De64F1840e5686e64278da901e261f20",
      L1StandardBridge: "0xfd0Bf71F60660E2f608ed56e1659C450eB113120",
    },
    [CHAIN_IDs.BLAST_SEPOLIA]: {
      L1BlastBridge: "0xc644cc19d2A9388b71dd1dEde07cFFC73237Dca8",
      L1CrossDomainMessenger: "0x9338F298F29D3918D5D1Feb209aeB9915CC96333",
      L1StandardBridge: "0xDeDa8D3CCf044fE2A16217846B6e1f1cfD8e122f",
    },
    [CHAIN_IDs.LISK_SEPOLIA]: {
      L1CrossDomainMessenger: "0x857824E6234f7733ecA4e9A76804fd1afa1A3A2C",
      L1StandardBridge: "0x1Fb30e446eA791cd1f011675E5F3f5311b70faF5",
    },
    [CHAIN_IDs.MODE_SEPOLIA]: {
      L1CrossDomainMessenger: "0xc19a60d9E8C27B9A43527c3283B4dd8eDC8bE15C",
      L1StandardBridge: "0xbC5C679879B2965296756CD959C3C739769995E2",
    },
    [CHAIN_IDs.OPTIMISM_SEPOLIA]: {
      L1CrossDomainMessenger: "0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef",
      L1StandardBridge: "0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1",
    },
    [CHAIN_IDs.UNICHAIN_SEPOLIA]: {
      L1CrossDomainMessenger: "0x448A37330A60494E666F6DD60aD48d930AEbA381",
      L1StandardBridge: "0xea58fcA6849d79EAd1f26608855c2D6407d54Ce2",
    },
  },
};

export const L2_ADDRESS_MAP: { [key: number]: { [contractName: string]: string } } = {
  [CHAIN_IDs.ALEPH_ZERO]: {
    l2GatewayRouter: "0xD296d45171B97720D3aBdb68B0232be01F1A9216",
  },
  [CHAIN_IDs.ARBITRUM_SEPOLIA]: {
    l2GatewayRouter: "0x9fDD1C4E4AA24EEc1d913FABea925594a20d43C7",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0xaCF1ceeF35caAc005e15888dDb8A3515C41B4872",
  },
  [CHAIN_IDs.ARBITRUM]: {
    l2GatewayRouter: "0x5288c571Fd7aD117beA99bF60FE0846C4E84F933",
    cctpTokenMessenger: "0x19330d10D9Cc8751218eaf51E8885D058642E08A",
    cctpMessageTransmitter: "0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca",
    uniswapV3SwapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.BSC]: {
    helios: "0xB04926aF663cB52899361B1F6313bcFEa5A58B29",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.POLYGON]: {
    fxChild: "0x8397259c983751DAf40400790063935a11afa28a",
    cctpTokenMessenger: "0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE",
    cctpMessageTransmitter: "0xF3be9355363857F3e001be68856A2f96b4C39Ba9",
    uniswapV3SwapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.POLYGON_AMOY]: {
    fxChild: "0xE5930336866d0388f0f745A2d9207C7781047C0f",
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
  },
  [CHAIN_IDs.ZK_SYNC]: {
    zkErc20Bridge: "0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102",
    cctpTokenMessenger: ZERO_ADDRESS, // CCTP not available on zkSync.
    "1inchV6Router": "0x6fd4383cB451173D5f9304F041C7BCBf27d561fF",
    permit2: "0x0000000000225e31d15943971f47ad3022f714fa",
  },
  [CHAIN_IDs.OPTIMISM]: {
    cctpTokenMessenger: "0x2B4069517957735bE00ceE0fadAE88a26365528f",
    cctpMessageTransmitter: "0x4d41f22c5a0e5c74090899e5a8fb597a8842b3e8",
    uniswapV3SwapRouter: "0xE592427A0AEce92De3Edee1F18E0157C05861564",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.OPTIMISM_SEPOLIA]: {
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
    uniswapV3SwapRouter: "0xd8866E76441df243fc98B892362Fc6264dC3ca80", // Mock_UniswapV3SwapRouter.sol
  },
  [CHAIN_IDs.BASE]: {
    cctpTokenMessenger: "0x1682Ae6375C4E4A97e4B583BC394c861A46D8962",
    cctpMessageTransmitter: "0xAD09780d193884d503182aD4588450C416D6F9D4",
    uniswapV3SwapRouter: "0x2626664c2603336E57B271c5C0b26F421741e481",
    "1inchV6Router": "0x111111125421cA6dc452d289314280a0f8842A65",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.BASE_SEPOLIA]: {
    cctpTokenMessenger: "0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5",
    cctpMessageTransmitter: "0x7865fAfC2db2093669d92c0F33AeEF291086BEFD",
    uniswapV3SwapRouter: "0x7945814de23d76dfff0cfc6ecb76456b9f7ac648", // Mock_UniswapV3SwapRouter.sol
  },
  [CHAIN_IDs.LENS]: {
    zkErc20Bridge: "0xfBEC23c5BB0E076F2ef4d0AaD7fe331aE5A01143",
    zkUSDCBridge: "0x7188B6975EeC82ae914b6eC7AC32b3c9a18b2c81",
    cctpTokenMessenger: ZERO_ADDRESS, // Not available on Lens.
    permit2: "0x0000000000225e31D15943971F47aD3022F714Fa",
  },
  [CHAIN_IDs.LENS_SEPOLIA]: {
    zkErc20Bridge: "0x427373Be173120D7A042b44D0804E37F25E7330b",
  },
  [CHAIN_IDs.LINEA]: {
    lineaMessageService: "0x508Ca82Df566dCD1B0DE8296e70a96332cD644ec",
    cctpV2TokenMessenger: "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d",
    lineaTokenBridge: "0x353012dc4a9A6cF55c941bADC267f82004A8ceB9",
    permit2: "0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768", // PancakeSwap Permit2
  },
  [CHAIN_IDs.SCROLL_SEPOLIA]: {
    scrollERC20GatewayRouter: "0x9aD3c5617eCAa556d6E166787A97081907171230",
    scrollGasPriceOracle: "0x5300000000000000000000000000000000000002",
    scrollMessenger: "0xba50f5340fb9f3bd074bd638c9be13ecb36e603d",
  },
  [CHAIN_IDs.SCROLL]: {
    scrollERC20GatewayRouter: "0x4C0926FF5252A435FD19e10ED15e5a249Ba19d79",
    scrollGasPriceOracle: "0x5300000000000000000000000000000000000002",
    scrollMessenger: "0x781e90f1c8Fc4611c9b7497C3B47F99Ef6969CbC",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  1442: {
    // Custom WETH for testing because there is no "official" WETH
    l2Weth: "0x3ab6C7AEb93A1CFC64AEEa8BF0f00c176EE42A2C",
    polygonZkEvmBridge: "0xF6BEEeBB578e214CA9E23B0e9683454Ff88Ed2A7",
  },
  [CHAIN_IDs.UNICHAIN]: {
    cctpTokenMessenger: "0x4e744b28E787c3aD0e810eD65A24461D4ac5a762",
    cctpMessageTransmitter: "0x353bE9E2E38AB1D19104534e4edC21c643Df86f4",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.UNICHAIN_SEPOLIA]: {
    cctpTokenMessenger: "0x8ed94B8dAd2Dc5453862ea5e316A8e71AAed9782",
    cctpMessageTransmitter: "0xbc498c326533d675cf571B90A2Ced265ACb7d086",
  },
  [CHAIN_IDs.BLAST]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.ZORA]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.WORLD_CHAIN]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.INK]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.SONEIUM]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.LISK]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.REDSTONE]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
  [CHAIN_IDs.MODE]: {
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  },
};

export const POLYGON_CHAIN_IDS: { [l1ChainId: number]: number } = {
  [CHAIN_IDs.MAINNET]: CHAIN_IDs.POLYGON,
  [CHAIN_IDs.SEPOLIA]: CHAIN_IDs.POLYGON_AMOY,
};

/**
 * An official mapping of chain IDs to CCTP domains. This mapping is separate from chain identifiers
 * and is an internal mappinng maintained by Circle.
 * @link https://developers.circle.com/stablecoins/docs/supported-domains
 */
export const CIRCLE_DOMAIN_IDs = Object.fromEntries(
  Object.entries(PUBLIC_NETWORKS).map(([chainId, { cctpDomain }]) => [Number(chainId), cctpDomain])
);

const createChainMap = <T>(selector: (network: any) => T) =>
  new Map(Object.entries(PUBLIC_NETWORKS).map(([id, network]) => [Number(id), selector(network)]));

/**
 * Mapping chainId => oft endpoint id
 * @link https://docs.layerzero.network/v2/deployments/deployed-contracts
 */
export const OFT_EIDs = createChainMap<number>((network) => network.oftEid);
