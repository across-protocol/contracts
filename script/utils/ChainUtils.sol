// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @title ChainUtils
 * @notice Utility contract for handling chain-specific constants and addresses
 * @dev This library mirrors the functionality of the TypeScript constants files
 */
abstract contract ChainUtils is Script {
    // Chain IDs
    uint256 constant MAINNET = 1;
    uint256 constant SEPOLIA = 11155111;
    uint256 constant OPTIMISM = 10;
    uint256 constant OPTIMISM_SEPOLIA = 11155420;
    uint256 constant ARBITRUM = 42161;
    uint256 constant ARBITRUM_SEPOLIA = 421614;
    uint256 constant POLYGON = 137;
    uint256 constant POLYGON_AMOY = 80002;
    uint256 constant BOBA = 288;
    uint256 constant BASE = 8453;
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant ZK_SYNC = 324;
    uint256 constant LINEA = 59144;
    uint256 constant SCROLL = 534352;
    uint256 constant SCROLL_SEPOLIA = 534351;
    uint256 constant BLAST = 81457;
    uint256 constant BLAST_SEPOLIA = 168587773;
    uint256 constant MODE = 34443;
    uint256 constant MODE_SEPOLIA = 919;
    uint256 constant LISK = 232; // Actual ChainID from deployments.json
    uint256 constant LISK_SEPOLIA = 4249108710;
    uint256 constant REDSTONE = 57073; // Actual ChainID from deployments.json
    uint256 constant WORLD_CHAIN = 8888881;
    uint256 constant ZORA = 7777777;
    uint256 constant ALEPH_ZERO = 41455; // Actual ChainID from deployments.json
    uint256 constant INK = 111;
    uint256 constant TATARA = 8082;
    uint256 constant LENS = 1698046797;
    uint256 constant LENS_SEPOLIA = 1895502950;
    uint256 constant CHER = 88888;
    uint256 constant SONEIUM = 2718345;
    uint256 constant UNICHAIN = 698888;
    uint256 constant UNICHAIN_SEPOLIA = 699999;
    // Additional chain IDs
    uint256 constant BSC = 56;

    // Zero address constant
    address constant ZERO_ADDRESS = address(0);

    // Get L1 contract address based on chain ID and contract name
    function getL1Address(uint256 chainId, string memory contractName) public pure returns (address) {
        // Mainnet addresses
        if (chainId == MAINNET) {
            if (compareStrings(contractName, "finder")) return 0x40f941E48A552bF496B154Af6bf55725f18D77c3;
            if (compareStrings(contractName, "l1ArbitrumInbox")) return 0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f;
            if (compareStrings(contractName, "l1ERC20GatewayRouter")) return 0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef;
            if (compareStrings(contractName, "polygonRootChainManager"))
                return 0xA0c68C638235ee32657e8f720a23ceC1bFc77C77;
            if (compareStrings(contractName, "polygonFxRoot")) return 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2;
            if (compareStrings(contractName, "polygonERC20Predicate"))
                return 0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf;
            if (compareStrings(contractName, "polygonRegistry")) return 0x33a02E6cC863D393d6Bf231B697b82F6e499cA71;
            if (compareStrings(contractName, "polygonDepositManager"))
                return 0x401F6c983eA34274ec46f84D70b31C151321188b;
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0xBd3fa81B58Ba92a82136038B25aDec7066af3155;
            if (compareStrings(contractName, "cctpV2TokenMessenger")) return 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0x0a992d191DEeC32aFe36203Ad87D7d289a738F81;
            if (compareStrings(contractName, "lineaMessageService")) return 0xd19d4B5d358258f05D7B411E21A1460D11B0876F;
            if (compareStrings(contractName, "lineaTokenBridge")) return 0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319;
            if (compareStrings(contractName, "scrollERC20GatewayRouter"))
                return 0xF8B1378579659D8F7EE5f3C929c2f3E332E41Fd6;
            if (compareStrings(contractName, "scrollMessengerRelay")) return 0x6774Bcbd5ceCeF1336b5300fb5186a12DDD8b367;
            if (compareStrings(contractName, "scrollGasPriceOracle")) return 0x0d7E906BD9cAFa154b048cFa766Cc1E54E39AF9B;
            if (compareStrings(contractName, "blastYieldManager")) return 0xa230285d5683C74935aD14c446e137c8c8828438;
            if (compareStrings(contractName, "blastDaiRetriever")) return 0x98Dd57048d7d5337e92D9102743528ea4Fea64aB;
            if (compareStrings(contractName, "l1AlephZeroInbox")) return 0x56D8EC76a421063e1907503aDd3794c395256AEb;
            if (compareStrings(contractName, "l1AlephZeroERC20GatewayRouter"))
                return 0xeBb17f398ed30d02F2e8733e7c1e5cf566e17812;
            if (compareStrings(contractName, "donationBox")) return 0x0d57392895Db5aF3280e9223323e20F3951E81B1;
            if (compareStrings(contractName, "zkBridgeHub")) return 0x303a465B659cBB0ab36eE643eA362c509EEb5213;
            if (compareStrings(contractName, "dai")) return 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        }
        // Sepolia addresses
        else if (chainId == SEPOLIA) {
            if (compareStrings(contractName, "finder")) return 0xeF684C38F94F48775959ECf2012D7E864ffb9dd4;
            if (compareStrings(contractName, "l1ArbitrumInbox")) return 0xaAe29B0366299461418F5324a79Afc425BE5ae21;
            if (compareStrings(contractName, "l1ERC20GatewayRouter")) return 0xcE18836b233C83325Cc8848CA4487e94C6288264;
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
            if (compareStrings(contractName, "usdc")) return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            if (compareStrings(contractName, "lineaMessageService")) return 0xd19d4B5d358258f05D7B411E21A1460D11B0876F;
            if (compareStrings(contractName, "lineaTokenBridge")) return 0x051F1D88f0aF5763fB888eC4378b4D8B29ea3319;
            if (compareStrings(contractName, "scrollERC20GatewayRouter"))
                return 0x13FBE0D0e5552b8c9c4AE9e2435F38f37355998a;
            if (compareStrings(contractName, "scrollMessengerRelay")) return 0x50c7d3e7f7c656493D1D76aaa1a836CedfCBB16A;
            if (compareStrings(contractName, "scrollGasPriceOracle")) return 0x247969F4fad93a33d4826046bc3eAE0D36BdE548;
            if (compareStrings(contractName, "donationBox")) return 0x74f00724075443Cbbf55129F17CbAB0F77bA0722;
            if (compareStrings(contractName, "polygonRootChainManager"))
                return 0x34F5A25B627f50Bb3f5cAb72807c4D4F405a9232;
            if (compareStrings(contractName, "polygonFxRoot")) return 0x0E13EBEdDb8cf9f5987512d5E081FdC2F5b0991e;
            if (compareStrings(contractName, "polygonERC20Predicate"))
                return 0x4258C75b752c812B7Fa586bdeb259f2d4bd17f4F;
            if (compareStrings(contractName, "polygonRegistry")) return 0xfE92F7c3a701e43d8479738c8844bCc555b9e5CD;
            if (compareStrings(contractName, "polygonDepositManager"))
                return 0x44Ad17990F9128C6d823Ee10dB7F0A5d40a731A4;
            if (compareStrings(contractName, "zkBridgeHub")) return 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE;
            if (compareStrings(contractName, "dai")) return 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Sepolia DAI
        }

        // If nothing matches, revert
        revert(string.concat("No address found for ", contractName, " on chainId ", vm.toString(chainId)));
    }

    // Get WETH address for the given chain ID
    function getWETH(uint256 chainId) public pure returns (address) {
        if (chainId == MAINNET) return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        if (chainId == SEPOLIA) return 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
        if (chainId == OPTIMISM) return 0x4200000000000000000000000000000000000006;
        if (chainId == OPTIMISM_SEPOLIA) return 0x4200000000000000000000000000000000000006;
        if (chainId == ARBITRUM) return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        if (chainId == ARBITRUM_SEPOLIA) return 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
        if (chainId == POLYGON) return 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        if (chainId == POLYGON_AMOY) return 0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889;
        if (chainId == BASE) return 0x4200000000000000000000000000000000000006;
        if (chainId == BASE_SEPOLIA) return 0x4200000000000000000000000000000000000006;
        if (chainId == LINEA) return 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;
        if (chainId == BLAST) return 0x4300000000000000000000000000000000000004;
        if (chainId == BLAST_SEPOLIA) return 0x4300000000000000000000000000000000000004;

        // If no WETH address is found, revert
        revert(string.concat("No WETH address found for chainId ", vm.toString(chainId)));
    }

    // Get USDC address for the given chain ID
    function getUSDC(uint256 chainId) public pure returns (address) {
        if (chainId == MAINNET) return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        if (chainId == SEPOLIA) return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        if (chainId == OPTIMISM) return 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
        if (chainId == OPTIMISM_SEPOLIA) return 0x5fd84259d66Cd46123540766Be93DFE6D43130D7;
        if (chainId == ARBITRUM) return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        if (chainId == ARBITRUM_SEPOLIA) return 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
        if (chainId == POLYGON) return 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
        if (chainId == POLYGON_AMOY) return 0x2c852e740B62308c46DD29B982FBb650D063Bd07;
        if (chainId == BASE) return 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
        if (chainId == BASE_SEPOLIA) return 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        if (chainId == BLAST) return 0x4300000000000000000000000000000000000003; // Actually USDB
        if (chainId == BLAST_SEPOLIA) return 0x4300000000000000000000000000000000000003; // Actually USDB

        // If no USDC address is found, revert
        revert(string.concat("No USDC address found for chainId ", vm.toString(chainId)));
    }

    // Get L2 contract address based on chain ID and contract name
    function getL2Address(uint256 chainId, string memory contractName) public pure virtual returns (address) {
        // Arbitrum addresses
        if (chainId == ARBITRUM) {
            if (compareStrings(contractName, "l2GatewayRouter")) return 0x5288c571Fd7aD117beA99bF60FE0846C4E84F933;
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x19330d10D9Cc8751218eaf51E8885D058642E08A;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca;
            if (compareStrings(contractName, "uniswapV3SwapRouter")) return 0xE592427A0AEce92De3Edee1F18E0157C05861564;
            if (compareStrings(contractName, "1inchV6Router")) return 0x111111125421cA6dc452d289314280a0f8842A65;
        }
        // Arbitrum Sepolia addresses
        else if (chainId == ARBITRUM_SEPOLIA) {
            if (compareStrings(contractName, "l2GatewayRouter")) return 0x9fDD1C4E4AA24EEc1d913FABea925594a20d43C7;
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0xaCF1ceeF35caAc005e15888dDb8A3515C41B4872;
        }
        // Optimism addresses
        else if (chainId == OPTIMISM) {
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x2B4069517957735bE00ceE0fadAE88a26365528f;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0x4D41f22c5a0e5c74090899E5a8Fb597a8842b3e8;
            if (compareStrings(contractName, "uniswapV3SwapRouter")) return 0xE592427A0AEce92De3Edee1F18E0157C05861564;
            if (compareStrings(contractName, "1inchV6Router")) return 0x111111125421cA6dc452d289314280a0f8842A65;
        }
        // Optimism Sepolia addresses
        else if (chainId == OPTIMISM_SEPOLIA) {
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
            if (compareStrings(contractName, "uniswapV3SwapRouter")) return 0xd8866E76441df243fc98B892362Fc6264dC3ca80;
        }
        // Polygon addresses
        else if (chainId == POLYGON) {
            if (compareStrings(contractName, "fxChild")) return 0x8397259c983751DAf40400790063935a11afa28a;
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0xF3be9355363857F3e001be68856A2f96b4C39Ba9;
            if (compareStrings(contractName, "uniswapV3SwapRouter")) return 0xE592427A0AEce92De3Edee1F18E0157C05861564;
            if (compareStrings(contractName, "1inchV6Router")) return 0x111111125421cA6dc452d289314280a0f8842A65;
        }
        // Polygon Amoy (testnet) addresses
        else if (chainId == POLYGON_AMOY) {
            if (compareStrings(contractName, "fxChild")) return 0xE5930336866d0388f0f745A2d9207C7781047C0f;
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
        }
        // Base addresses
        else if (chainId == BASE) {
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x1682Ae6375C4E4A97e4B583BC394c861A46D8962;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0xAD09780d193884d503182aD4588450C416D6F9D4;
            if (compareStrings(contractName, "uniswapV3SwapRouter")) return 0x2626664c2603336E57B271c5C0b26F421741e481;
            if (compareStrings(contractName, "1inchV6Router")) return 0x111111125421cA6dc452d289314280a0f8842A65;
        }
        // Base Sepolia addresses
        else if (chainId == BASE_SEPOLIA) {
            if (compareStrings(contractName, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
            if (compareStrings(contractName, "cctpMessageTransmitter"))
                return 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
            if (compareStrings(contractName, "uniswapV3SwapRouter")) return 0x7945814dE23D76dfFf0CFC6ecB76456B9F7Ac648;
        }
        // Blast addresses
        else if (chainId == BLAST) {
            if (compareStrings(contractName, "wrappedNative")) return 0x4300000000000000000000000000000000000004;
            if (compareStrings(contractName, "usdb")) return 0x4300000000000000000000000000000000000003;
            if (compareStrings(contractName, "blastYieldManager")) return 0x4300000000000000000000000000000000000002;
        }
        // Blast Sepolia addresses
        else if (chainId == BLAST_SEPOLIA) {
            if (compareStrings(contractName, "wrappedNative")) return 0x4300000000000000000000000000000000000004;
            if (compareStrings(contractName, "usdb")) return 0x4300000000000000000000000000000000000003;
            if (compareStrings(contractName, "blastYieldManager")) return 0x4300000000000000000000000000000000000002;
        }

        // If nothing matches, revert
        revert(string.concat("No L2 address found for ", contractName, " on chainId ", vm.toString(chainId)));
    }

    // Get WMATIC address for Polygon chains
    function getWMATIC(uint256 chainId) public pure virtual returns (address) {
        if (chainId == POLYGON) return 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        if (chainId == POLYGON_AMOY) return 0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889;
        revert(string.concat("No WMATIC address found for chainId ", vm.toString(chainId)));
    }

    // Get MATIC token address on Ethereum chains
    function getMATIC(uint256 chainId) public pure returns (address) {
        if (chainId == MAINNET) return 0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0;
        if (chainId == SEPOLIA) return 0x655F2166b0709cd575202630952D71E2bB0d61Af;
        revert(string.concat("No MATIC address found for chainId ", vm.toString(chainId)));
    }

    // Helper to compare strings
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
