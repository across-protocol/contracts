// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";

/**
 * @title Constants
 * @notice Contains constants used in deployment scripts, converted from consts.ts
 */
contract Constants {
    // Chain IDs
    uint256 constant MAINNET = 1;
    uint256 constant SEPOLIA = 11155111;
    uint256 constant ARBITRUM = 42161;
    uint256 constant ARBITRUM_SEPOLIA = 421614;
    uint256 constant BSC = 56;
    uint256 constant POLYGON = 137;
    uint256 constant POLYGON_AMOY = 80002;
    uint256 constant ZK_SYNC = 324;
    uint256 constant OPTIMISM = 10;
    uint256 constant OPTIMISM_SEPOLIA = 11155420;
    uint256 constant BASE = 8453;
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant LENS = 232;
    uint256 constant LENS_TESTNET = 37111;
    uint256 constant LINEA = 59144;
    uint256 constant LINEA_SEPOLIA = 59141;
    uint256 constant SCROLL = 534352;
    uint256 constant SCROLL_SEPOLIA = 534351;
    uint256 constant UNICHAIN = 130;
    uint256 constant UNICHAIN_SEPOLIA = 1301;
    uint256 constant ALEPH_ZERO = 41455;
    uint256 constant BLAST = 81457;
    uint256 constant BLAST_SEPOLIA = 168587773;
    uint256 constant BOBA = 288;
    uint256 constant INK = 57073;
    uint256 constant INK_SEPOLIA = 763373;
    uint256 constant LISK = 1135;
    uint256 constant LISK_SEPOLIA = 4202;
    uint256 constant MODE = 34443;
    uint256 constant MODE_SEPOLIA = 919;
    uint256 constant REDSTONE = 690;
    uint256 constant SONEIUM = 1868;
    uint256 constant WORLD_CHAIN = 480;
    uint256 constant ZORA = 7777777;

    // Token addresses
    WETH9Interface constant WETH_MAINNET = WETH9Interface(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    WETH9Interface constant WETH_SEPOLIA = WETH9Interface(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
    WETH9Interface constant WETH_ARBITRUM = WETH9Interface(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    WETH9Interface constant WETH_ARBITRUM_SEPOLIA = WETH9Interface(0x980B62Da83eFf3D4576C647993b0c1D7faf17c73);
    WETH9Interface constant WETH_BSC = WETH9Interface(0x4DB5a66E937A9F4473fA95b1cAF1d1E1D62E29EA); // WBNB acts as WETH on BSC
    WETH9Interface constant WETH_POLYGON = WETH9Interface(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    WETH9Interface constant WETH_POLYGON_AMOY = WETH9Interface(0x360ad4f9a9A8EFe9A8DCB5f461c4Cc1047E1Dcf9);
    WETH9Interface constant WETH_ZK_SYNC = WETH9Interface(0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91);
    WETH9Interface constant WETH_OPTIMISM = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_OPTIMISM_SEPOLIA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_BASE = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_BASE_SEPOLIA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_LENS = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_LENS_TESTNET = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_LINEA = WETH9Interface(0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f);
    WETH9Interface constant WETH_LINEA_SEPOLIA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_SCROLL_SEPOLIA = WETH9Interface(0x5300000000000000000000000000000000000004);
    WETH9Interface constant WETH_SCROLL = WETH9Interface(0x5300000000000000000000000000000000000004);
    WETH9Interface constant WETH_UNICHAIN = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_UNICHAIN_SEPOLIA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_ALEPH_ZERO = WETH9Interface(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // Assuming bridged WETH
    WETH9Interface constant WETH_BLAST = WETH9Interface(0x4300000000000000000000000000000000000004);
    WETH9Interface constant WETH_BLAST_SEPOLIA = WETH9Interface(0x4300000000000000000000000000000000000004);
    WETH9Interface constant WETH_BOBA = WETH9Interface(0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000);
    WETH9Interface constant WETH_INK = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_LISK = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_LISK_SEPOLIA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_MODE = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_MODE_SEPOLIA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_REDSTONE = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_SONEIUM = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_WORLD_CHAIN = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_ZORA = WETH9Interface(0x4200000000000000000000000000000000000006);
    WETH9Interface constant WETH_POLYGON_ZKEVM = WETH9Interface(0x3ab6C7AEb93A1CFC64AEEa8BF0f00c176EE42A2C); // Custom WETH for testing

    // Aleph Zero
    address constant ALEPH_ZERO_L2_GATEWAY_ROUTER = 0xD296d45171B97720D3aBdb68B0232be01F1A9216;

    // Arbitrum Sepolia
    address constant ARBITRUM_SEPOLIA_L2_GATEWAY_ROUTER = 0x9fDD1C4E4AA24EEc1d913FABea925594a20d43C7;
    address constant ARBITRUM_SEPOLIA_CCTP_TOKEN_MESSENGER = 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
    address constant ARBITRUM_SEPOLIA_CCTP_MESSAGE_TRANSMITTER = 0xaCF1ceeF35caAc005e15888dDb8A3515C41B4872;

    // Arbitrum
    address constant ARBITRUM_L2_GATEWAY_ROUTER = 0x5288c571Fd7aD117beA99bF60FE0846C4E84F933;
    address constant ARBITRUM_CCTP_TOKEN_MESSENGER = 0x19330d10D9Cc8751218eaf51E8885D058642E08A;
    address constant ARBITRUM_CCTP_MESSAGE_TRANSMITTER = 0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca;
    address constant ARBITRUM_UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant ARBITRUM_1INCH_V6_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // BSC
    address constant BSC_HELIOS = 0xCdb25d0A6FfFE639BC591a565F2D99507837f2b7;

    // Polygon
    address constant POLYGON_FX_CHILD = 0x8397259c983751DAf40400790063935a11afa28a;
    address constant POLYGON_CCTP_TOKEN_MESSENGER = 0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE;
    address constant POLYGON_CCTP_MESSAGE_TRANSMITTER = 0xF3be9355363857F3e001be68856A2f96b4C39Ba9;
    address constant POLYGON_UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant POLYGON_1INCH_V6_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Polygon Amoy
    address constant POLYGON_AMOY_FX_CHILD = 0xE5930336866d0388f0f745A2d9207C7781047C0f;
    address constant POLYGON_AMOY_CCTP_TOKEN_MESSENGER = 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
    address constant POLYGON_AMOY_CCTP_MESSAGE_TRANSMITTER = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;

    // ZkSync
    address constant ZK_SYNC_ZK_ERC20_BRIDGE = 0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102;
    address constant ZK_SYNC_1INCH_V6_ROUTER = 0x6fd4383cB451173D5f9304F041C7BCBf27d561fF;

    // Optimism
    address constant OPTIMISM_CCTP_TOKEN_MESSENGER = 0x2B4069517957735bE00ceE0fadAE88a26365528f;
    address constant OPTIMISM_CCTP_MESSAGE_TRANSMITTER = 0x4D41f22c5a0e5c74090899E5a8Fb597a8842b3e8;
    address constant OPTIMISM_UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant OPTIMISM_SYNC_1INCH_V6_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Optimism Sepolia
    address constant OPTIMISM_SEPOLIA_CCTP_TOKEN_MESSENGER = 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
    address constant OPTIMISM_SEPOLIA_CCTP_MESSAGE_TRANSMITTER = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
    address constant OPTIMISM_SEPOLIA_UNISWAP_V3_SWAP_ROUTER = 0xd8866E76441df243fc98B892362Fc6264dC3ca80;

    // Base
    address constant BASE_CCTP_TOKEN_MESSENGER = 0x1682Ae6375C4E4A97e4B583BC394c861A46D8962;
    address constant BASE_CCTP_MESSAGE_TRANSMITTER = 0xAD09780d193884d503182aD4588450C416D6F9D4;
    address constant BASE_UNISWAP_V3_SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant BASE_SYNC_1INCH_V6_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    // Base Sepolia
    address constant BASE_SEPOLIA_CCTP_TOKEN_MESSENGER = 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
    address constant BASE_SEPOLIA_CCTP_MESSAGE_TRANSMITTER = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
    address constant BASE_SEPOLIA_UNISWAP_V3_SWAP_ROUTER = 0x7945814dE23D76dfFf0CFC6ecB76456B9F7Ac648;

    // Lens
    address constant LENS_ZK_ERC20_BRIDGE = 0xfBEC23c5BB0E076F2ef4d0AaD7fe331aE5A01143;
    address constant LENS_ZK_USDC_BRIDGE = 0x7188B6975EeC82ae914b6eC7AC32b3c9a18b2c81;

    // Lens Testnet
    address constant LENS_TESTNET_ZK_ERC20_BRIDGE = 0x427373Be173120D7A042b44D0804E37F25E7330b;

    // Linea
    address constant LINEA_LINEA_MESSAGE_SERVICE = 0x508Ca82Df566dCD1B0DE8296e70a96332cD644ec;
    address constant LINEA_CCTP_V2_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant LINEA_LINEA_TOKEN_BRIDGE = 0x353012dc4a9A6cF55c941bADC267f82004A8ceB9;

    // Scroll
    address constant SCROLL_SCROLL_ERC20_GATEWAY_ROUTER = 0x4C0926FF5252A435FD19e10ED15e5a249Ba19d79;
    address constant SCROLL_SCROLL_GAS_PRICE_ORACLE = 0x5300000000000000000000000000000000000002;
    address constant SCROLL_SCROLL_MESSENGER = 0x781e90f1c8Fc4611c9b7497C3B47F99Ef6969CbC;

    // Scroll Sepolia
    address constant SCROLL_SEPOLIA_SCROLL_ERC20_GATEWAY_ROUTER = 0x9aD3c5617eCAa556d6E166787A97081907171230;
    address constant SCROLL_SEPOLIA_SCROLL_GAS_PRICE_ORACLE = 0x5300000000000000000000000000000000000002;
    address constant SCROLL_SEPOLIA_SCROLL_MESSENGER = 0xBa50f5340FB9F3Bd074bD638c9BE13eCB36E603d;

    // Polygon ZkEvm
    address constant POLYGON_ZKEVM_L2_WETH = 0x3ab6C7AEb93A1CFC64AEEa8BF0f00c176EE42A2C;
    address constant POLYGON_ZKEVM_POLYGON_ZK_EVM_BRIDGE = 0xF6BEEeBB578e214CA9E23B0e9683454Ff88Ed2A7;

    // Unichain
    address constant UNICHAIN_CCTP_TOKEN_MESSENGER = 0x4e744b28E787c3aD0e810eD65A24461D4ac5a762;
    address constant UNICHAIN_CCTP_MESSAGE_TRANSMITTER = 0x353bE9E2E38AB1D19104534e4edC21c643Df86f4;

    // Unichain Sepolia
    address constant UNICHAIN_SEPOLIA_CCTP_TOKEN_MESSENGER = 0x8ed94B8dAd2Dc5453862ea5e316A8e71AAed9782;
    address constant UNICHAIN_SEPOLIA_CCTP_MESSAGE_TRANSMITTER = 0xbc498c326533d675cf571B90A2Ced265ACb7d086;

    // Other constants
    address constant ZERO_ADDRESS = address(0);

    // Time constants
    uint256 constant QUOTE_TIME_BUFFER = 3600;
    uint256 constant FILL_DEADLINE_BUFFER = 6 * 3600;

    // L1 Address Map
    struct L1Addresses {
        address finder;
        address l1ArbitrumInbox;
        address l1ERC20GatewayRouter;
        address polygonRootChainManager;
        address polygonFxRoot;
        address polygonERC20Predicate;
        address polygonRegistry;
        address polygonDepositManager;
        address cctpTokenMessenger;
        address cctpV2TokenMessenger;
        address cctpMessageTransmitter;
        address lineaMessageService;
        address lineaTokenBridge;
        address scrollERC20GatewayRouter;
        address scrollMessengerRelay;
        address scrollGasPriceOracle;
        address blastYieldManager;
        address blastDaiRetriever;
        address l1AlephZeroInbox;
        address l1AlephZeroERC20GatewayRouter;
        address donationBox;
        address hubPoolStore;
        address zkBridgeHub;
        address zkUsdcSharedBridge_232;
        address zkUsdcSharedBridge_324;
    }

    // L2 Address Map
    struct L2Addresses {
        address l2GatewayRouter;
        address fxChild;
        address cctpTokenMessenger;
        address cctpMessageTransmitter;
        address uniswapV3SwapRouter;
        address helios;
        address zkErc20Bridge;
        address zkUSDCBridge;
        address lineaMessageService;
        address cctpV2TokenMessenger;
        address lineaTokenBridge;
        address scrollERC20GatewayRouter;
        address scrollGasPriceOracle;
        address scrollMessenger;
        address l2Weth;
        address polygonZkEvmBridge;
    }

    // OP Stack Address Map
    struct OpStackAddresses {
        address L1CrossDomainMessenger;
        address L1StandardBridge;
        address L1BlastBridge;
        address L1OpUSDCBridgeAdapter;
    }

    // Helper functions to get addresses for a specific chain
    function getL1Addresses(uint256 chainId) public pure returns (L1Addresses memory) {
        if (chainId == MAINNET) {
            return
                L1Addresses({
                    finder: 0x40f941E48A552bF496B154Af6bf55725f18D77c3,
                    l1ArbitrumInbox: 0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f,
                    l1ERC20GatewayRouter: 0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef,
                    polygonRootChainManager: 0xA0c68C638235ee32657e8f720a23ceC1bFc77C77,
                    polygonFxRoot: 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2,
                    polygonERC20Predicate: 0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf,
                    polygonRegistry: 0x33a02E6cC863D393d6Bf231B697b82F6e499cA71,
                    polygonDepositManager: 0x401F6c983eA34274ec46f84D70b31C151321188b,
                    cctpTokenMessenger: 0xBd3fa81B58Ba92a82136038B25aDec7066af3155,
                    cctpV2TokenMessenger: 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d,
                    cctpMessageTransmitter: 0x0a992d191DEeC32aFe36203Ad87D7d289a738F81,
                    lineaMessageService: 0xd19d4B5d358258f05D7B411E21A1460D11B0876F,
                    lineaTokenBridge: 0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319,
                    scrollERC20GatewayRouter: 0xF8B1378579659D8F7EE5f3C929c2f3E332E41Fd6,
                    scrollMessengerRelay: 0x6774Bcbd5ceCeF1336b5300fb5186a12DDD8b367,
                    scrollGasPriceOracle: 0x56971da63A3C0205184FEF096E9ddFc7A8C2D18a,
                    blastYieldManager: 0xa230285d5683C74935aD14c446e137c8c8828438,
                    blastDaiRetriever: 0x98Dd57048d7d5337e92D9102743528ea4Fea64aB,
                    l1AlephZeroInbox: 0x56D8EC76a421063e1907503aDd3794c395256AEb,
                    l1AlephZeroERC20GatewayRouter: 0xeBb17f398ed30d02F2e8733e7c1e5cf566e17812,
                    donationBox: 0x0d57392895Db5aF3280e9223323e20F3951E81B1,
                    hubPoolStore: 0x1Ace3BbD69b63063F859514Eca29C9BDd8310E61,
                    zkBridgeHub: 0x303a465B659cBB0ab36eE643eA362c509EEb5213,
                    zkUsdcSharedBridge_232: 0xf553E6D903AA43420ED7e3bc2313bE9286A8F987,
                    zkUsdcSharedBridge_324: 0xD7f9f54194C633F36CCD5F3da84ad4a1c38cB2cB
                });
        } else if (chainId == SEPOLIA) {
            return
                L1Addresses({
                    finder: 0xeF684C38F94F48775959ECf2012D7E864ffb9dd4,
                    l1ArbitrumInbox: 0xaAe29B0366299461418F5324a79Afc425BE5ae21,
                    l1ERC20GatewayRouter: 0xcE18836b233C83325Cc8848CA4487e94C6288264,
                    polygonRootChainManager: 0x34F5A25B627f50Bb3f5cAb72807c4D4F405a9232,
                    polygonFxRoot: 0x0E13EBEdDb8cf9f5987512d5E081FdC2F5b0991e,
                    polygonERC20Predicate: 0x4258C75b752c812B7Fa586bdeb259f2d4bd17f4F,
                    polygonRegistry: 0xfE92F7c3a701e43d8479738c8844bCc555b9e5CD,
                    polygonDepositManager: 0x44Ad17990F9128C6d823Ee10dB7F0A5d40a731A4,
                    cctpTokenMessenger: 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5,
                    cctpV2TokenMessenger: address(0), // Not deployed on Sepolia
                    cctpMessageTransmitter: 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD,
                    lineaMessageService: 0xd19d4B5d358258f05D7B411E21A1460D11B0876F,
                    lineaTokenBridge: 0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319,
                    scrollERC20GatewayRouter: 0x13FBE0D0e5552b8c9c4AE9e2435F38f37355998a,
                    scrollMessengerRelay: 0x50c7d3e7f7c656493D1D76aaa1a836CedfCBB16A,
                    scrollGasPriceOracle: 0x247969F4fad93a33d4826046bc3eAE0D36BdE548,
                    blastYieldManager: address(0), // Not deployed on Sepolia
                    blastDaiRetriever: address(0), // Not deployed on Sepolia
                    l1AlephZeroInbox: address(0), // Not deployed on Sepolia
                    l1AlephZeroERC20GatewayRouter: address(0), // Not deployed on Sepolia
                    donationBox: 0x74f00724075443Cbbf55129F17CbAB0F77bA0722,
                    hubPoolStore: address(0), // Not deployed on Sepolia
                    zkBridgeHub: 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE,
                    zkUsdcSharedBridge_232: address(0), // Not deployed on Sepolia
                    zkUsdcSharedBridge_324: address(0) // Not deployed on Sepolia
                });
        }
        revert("Unsupported chain ID");
    }

    function getOpStackAddresses(uint256 hubChainId, uint256 spokeChainId)
        public
        pure
        returns (OpStackAddresses memory)
    {
        if (hubChainId == MAINNET) {
            if (spokeChainId == BASE) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa,
                        L1StandardBridge: 0x3154Cf16ccdb4C6d922629664174b904d80F2C35,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == BOBA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x6D4528d192dB72E282265D6092F4B872f9Dff69e,
                        L1StandardBridge: 0xdc1664458d2f0B6090bEa60A8793A4E66c2F1c00,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == BLAST) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x5D4472f31Bd9385709ec61305AFc749F0fA8e9d0,
                        L1StandardBridge: 0x697402166Fbf2F22E970df8a6486Ef171dbfc524,
                        L1BlastBridge: 0x3a05E5d33d7Ab3864D53aaEc93c8301C1Fa49115,
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == UNICHAIN) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x9A3D64E386C18Cb1d6d5179a9596A4B5736e98A6,
                        L1StandardBridge: 0x81014F44b0a345033bB2b3B21C7a1A308B35fEeA,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == INK) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x69d3Cf86B2Bf1a9e99875B7e2D9B6a84426c171f,
                        L1StandardBridge: 0x88FF1e5b602916615391F55854588EFcBB7663f0,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: ZERO_ADDRESS
                    });
            } else if (spokeChainId == LISK) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x31B72D76FB666844C41EdF08dF0254875Dbb7edB,
                        L1StandardBridge: 0x2658723Bf70c7667De6B25F99fcce13A16D25d08,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: 0xE3622468Ea7dD804702B56ca2a4f88C0936995e6
                    });
            } else if (spokeChainId == MODE) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x95bDCA6c8EdEB69C98Bd5bd17660BaCef1298A6f,
                        L1StandardBridge: 0x735aDBbE72226BD52e818E7181953f42E3b0FF21,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == OPTIMISM) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1,
                        L1StandardBridge: 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == REDSTONE) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x592C1299e0F8331D81A28C0FC7352Da24eDB444a,
                        L1StandardBridge: 0xc473ca7E02af24c129c2eEf51F2aDf0411c1Df69,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == SONEIUM) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x9CF951E3F74B644e621b36Ca9cea147a78D4c39f,
                        L1StandardBridge: 0xeb9bf100225c214Efc3E7C651ebbaDcF85177607,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: 0xC67A8c5f22b40274Ca7C4A56Db89569Ee2AD3FAb
                    });
            } else if (spokeChainId == WORLD_CHAIN) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0xf931a81D18B1766d15695ffc7c1920a62b7e710a,
                        L1StandardBridge: 0x470458C91978D2d929704489Ad730DC3E3001113,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: 0x153A69e4bb6fEDBbAaF463CB982416316c84B2dB
                    });
            } else if (spokeChainId == ZORA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0xdC40a14d9abd6F410226f1E6de71aE03441ca506,
                        L1StandardBridge: 0x3e2Ea9B92B7E48A52296fD261dc26fd995284631,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            }
        } else if (hubChainId == SEPOLIA) {
            if (spokeChainId == BASE_SEPOLIA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0xC34855F4De64F1840e5686e64278da901e261f20,
                        L1StandardBridge: 0xfd0Bf71F60660E2f608ed56e1659C450eB113120,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == BLAST_SEPOLIA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x9338F298F29D3918D5D1Feb209aeB9915CC96333,
                        L1StandardBridge: 0xDeDa8D3CCf044fE2A16217846B6e1f1cfD8e122f,
                        L1BlastBridge: 0xc644cc19d2A9388b71dd1dEde07cFFC73237Dca8,
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == LISK_SEPOLIA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x857824E6234f7733ecA4e9A76804fd1afa1A3A2C,
                        L1StandardBridge: 0x1Fb30e446eA791cd1f011675E5F3f5311b70faF5,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == MODE_SEPOLIA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0xc19a60d9E8C27B9A43527c3283B4dd8eDC8bE15C,
                        L1StandardBridge: 0xbC5C679879B2965296756CD959C3C739769995E2,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == OPTIMISM_SEPOLIA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef,
                        L1StandardBridge: 0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            } else if (spokeChainId == UNICHAIN_SEPOLIA) {
                return
                    OpStackAddresses({
                        L1CrossDomainMessenger: 0x448A37330A60494E666F6DD60aD48d930AEbA381,
                        L1StandardBridge: 0xea58fcA6849d79EAd1f26608855c2D6407d54Ce2,
                        L1BlastBridge: address(0),
                        L1OpUSDCBridgeAdapter: address(0)
                    });
            }
        }
        revert("Unsupported chain combination");
    }

    // Circle domain IDs mapping
    function getCircleDomainId(uint256 chainId) public pure returns (uint32) {
        if (chainId == MAINNET) return 0;
        if (chainId == ARBITRUM) return 3;
        if (chainId == OPTIMISM) return 2;
        if (chainId == BASE) return 6;
        if (chainId == POLYGON) return 7;
        if (chainId == LINEA) return 8;
        if (chainId == UNICHAIN) return 9;
        if (chainId == BLAST) return 10;
        if (chainId == SEPOLIA) return 0;
        if (chainId == ARBITRUM_SEPOLIA) return 0;
        if (chainId == OPTIMISM_SEPOLIA) return 0;
        if (chainId == BASE_SEPOLIA) return 0;
        if (chainId == POLYGON_AMOY) return 0;
        if (chainId == UNICHAIN_SEPOLIA) return 0;
        if (chainId == BLAST_SEPOLIA) return 0;
        revert("Unsupported chain ID");
    }

    // Get WETH address for any supported chain
    function getWETH(uint256 chainId) public pure returns (WETH9Interface) {
        if (chainId == MAINNET) return WETH_MAINNET;
        if (chainId == SEPOLIA) return WETH_SEPOLIA;
        if (chainId == ARBITRUM) return WETH_ARBITRUM;
        if (chainId == ARBITRUM_SEPOLIA) return WETH_ARBITRUM_SEPOLIA;
        if (chainId == BSC) return WETH_BSC;
        if (chainId == POLYGON) return WETH_POLYGON;
        if (chainId == POLYGON_AMOY) return WETH_POLYGON_AMOY;
        if (chainId == ZK_SYNC) return WETH_ZK_SYNC;
        if (chainId == OPTIMISM) return WETH_OPTIMISM;
        if (chainId == OPTIMISM_SEPOLIA) return WETH_OPTIMISM_SEPOLIA;
        if (chainId == BASE) return WETH_BASE;
        if (chainId == BASE_SEPOLIA) return WETH_BASE_SEPOLIA;
        if (chainId == LENS) return WETH_LENS;
        if (chainId == LENS_TESTNET) return WETH_LENS_TESTNET;
        if (chainId == LINEA) return WETH_LINEA;
        if (chainId == LINEA_SEPOLIA) return WETH_LINEA_SEPOLIA;
        if (chainId == SCROLL_SEPOLIA) return WETH_SCROLL_SEPOLIA;
        if (chainId == SCROLL) return WETH_SCROLL;
        if (chainId == UNICHAIN) return WETH_UNICHAIN;
        if (chainId == UNICHAIN_SEPOLIA) return WETH_UNICHAIN_SEPOLIA;
        if (chainId == ALEPH_ZERO) return WETH_ALEPH_ZERO;
        if (chainId == BLAST) return WETH_BLAST;
        if (chainId == BLAST_SEPOLIA) return WETH_BLAST_SEPOLIA;
        if (chainId == BOBA) return WETH_BOBA;
        if (chainId == INK) return WETH_INK;
        if (chainId == LISK) return WETH_LISK;
        if (chainId == LISK_SEPOLIA) return WETH_LISK_SEPOLIA;
        if (chainId == MODE) return WETH_MODE;
        if (chainId == MODE_SEPOLIA) return WETH_MODE_SEPOLIA;
        if (chainId == REDSTONE) return WETH_REDSTONE;
        if (chainId == SONEIUM) return WETH_SONEIUM;
        if (chainId == WORLD_CHAIN) return WETH_WORLD_CHAIN;
        if (chainId == ZORA) return WETH_ZORA;
        if (chainId == 1442) return WETH_POLYGON_ZKEVM; // PolygonZkEvm chain
        revert("Unsupported chain ID");
    }
}
