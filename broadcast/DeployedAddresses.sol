// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title DeployedAddresses
 * @notice This contract contains all deployed contract addresses from Foundry broadcast files
 * @dev Generated on: 2025-06-22T17:37:34.539Z
 * @dev This file is auto-generated. Do not edit manually.
 */
contract DeployedAddresses {
    // Mapping for dynamic address lookup
    // chainId => contractName => address
    mapping(uint256 => mapping(string => address)) private _addresses;

    // Mainnet (Chain ID: 1)

    // DeployPermissionSplitterProxy.s.sol
    address public immutable MAINNET_DEPLOYPERMISSIONSPLITTERPROXY_PERMISSIONSPLITTERPROXY;

    // AcrossConfigStore
    address public immutable MAINNET_ACROSSCONFIGSTORE_ACROSSCONFIGSTORE;

    // AcrossMerkleDistributor
    address public immutable MAINNET_ACROSSMERKLEDISTRIBUTOR_ACROSSMERKLEDISTRIBUTOR;

    // Arbitrum_Adapter
    address public immutable MAINNET_ARBITRUM_ADAPTER_ARBITRUM_ADAPTER;

    // Arbitrum_RescueAdapter
    address public immutable MAINNET_ARBITRUM_RESCUEADAPTER_ARBITRUM_RESCUEADAPTER;

    // Arbitrum_SendTokensAdapter
    address public immutable MAINNET_ARBITRUM_SENDTOKENSADAPTER_ARBITRUM_SENDTOKENSADAPTER;

    // Boba_Adapter
    address public immutable MAINNET_BOBA_ADAPTER_BOBA_ADAPTER;

    // Ethereum_Adapter
    address public immutable MAINNET_ETHEREUM_ADAPTER_ETHEREUM_ADAPTER;

    // SpokePool
    address public immutable MAINNET_SPOKEPOOL_SPOKEPOOL;

    // HubPool
    address public immutable MAINNET_HUBPOOL_HUBPOOL;

    // HubPoolStore
    address public immutable MAINNET_HUBPOOLSTORE_HUBPOOLSTORE;

    // LpTokenFactory
    address public immutable MAINNET_LPTOKENFACTORY_LPTOKENFACTORY;

    // Optimism_Adapter
    address public immutable MAINNET_OPTIMISM_ADAPTER_OPTIMISM_ADAPTER;

    // PolygonTokenBridger
    address public immutable MAINNET_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER;

    // Polygon_Adapter
    address public immutable MAINNET_POLYGON_ADAPTER_POLYGON_ADAPTER;

    // ZkSync_Adapter
    address public immutable MAINNET_ZKSYNC_ADAPTER_ZKSYNC_ADAPTER;

    // Base_Adapter
    address public immutable MAINNET_BASE_ADAPTER_BASE_ADAPTER;

    // Linea_Adapter
    address public immutable MAINNET_LINEA_ADAPTER_LINEA_ADAPTER;

    // BondToken
    address public immutable MAINNET_BONDTOKEN_BONDTOKEN;

    // SpokePoolVerifier
    address public immutable MAINNET_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // Mode_Adapter
    address public immutable MAINNET_MODE_ADAPTER_MODE_ADAPTER;

    // MulticallHandler
    address public immutable MAINNET_MULTICALLHANDLER_MULTICALLHANDLER;

    // Lisk_Adapter
    address public immutable MAINNET_LISK_ADAPTER_LISK_ADAPTER;

    // Universal_Adapter
    address public immutable MAINNET_UNIVERSAL_ADAPTER_UNIVERSAL_ADAPTER;

    // Blast_Adapter
    address public immutable MAINNET_BLAST_ADAPTER_BLAST_ADAPTER;

    // Scroll_Adapter
    address public immutable MAINNET_SCROLL_ADAPTER_SCROLL_ADAPTER;

    // Blast_DaiRetriever
    address public immutable MAINNET_BLAST_DAIRETRIEVER_BLAST_DAIRETRIEVER;

    // Blast_RescueAdapter
    address public immutable MAINNET_BLAST_RESCUEADAPTER_BLAST_RESCUEADAPTER;

    // Redstone_Adapter
    address public immutable MAINNET_REDSTONE_ADAPTER_REDSTONE_ADAPTER;

    // Zora_Adapter
    address public immutable MAINNET_ZORA_ADAPTER_ZORA_ADAPTER;

    // WorldChain_Adapter
    address public immutable MAINNET_WORLDCHAIN_ADAPTER_WORLDCHAIN_ADAPTER;

    // AlephZero_Adapter
    address public immutable MAINNET_ALEPHZERO_ADAPTER_ALEPHZERO_ADAPTER;

    // Ink_Adapter
    address public immutable MAINNET_INK_ADAPTER_INK_ADAPTER;

    // Cher_Adapter
    address public immutable MAINNET_CHER_ADAPTER_CHER_ADAPTER;

    // Lens_Adapter
    address public immutable MAINNET_LENS_ADAPTER_LENS_ADAPTER;

    // DoctorWho_Adapter
    address public immutable MAINNET_DOCTORWHO_ADAPTER_DOCTORWHO_ADAPTER;

    // Solana_Adapter
    address public immutable MAINNET_SOLANA_ADAPTER_SOLANA_ADAPTER;

    // Optimism (Chain ID: 10)

    // SpokePool
    address public immutable OPTIMISM_SPOKEPOOL_SPOKEPOOL;

    // 1inch_SwapAndBridge
    address public immutable OPTIMISM_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE;

    // UniswapV3_SwapAndBridge
    address public immutable OPTIMISM_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE;

    // AcrossMerkleDistributor
    address public immutable OPTIMISM_ACROSSMERKLEDISTRIBUTOR_ACROSSMERKLEDISTRIBUTOR;

    // SpokePoolVerifier
    address public immutable OPTIMISM_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable OPTIMISM_MULTICALLHANDLER_MULTICALLHANDLER;

    // BSC (Chain ID: 56)

    // SpokePool
    address public immutable BSC_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable BSC_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable BSC_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 130 (Chain ID: 130)

    // SpokePool
    address public immutable CHAIN_130_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_130_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_130_MULTICALLHANDLER_MULTICALLHANDLER;

    // Polygon (Chain ID: 137)

    // MintableERC1155
    address public immutable POLYGON_MINTABLEERC1155_MINTABLEERC1155;

    // PolygonTokenBridger
    address public immutable POLYGON_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER;

    // SpokePool
    address public immutable POLYGON_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable POLYGON_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // 1inch_UniversalSwapAndBridge
    address public immutable POLYGON_1INCH_UNIVERSALSWAPANDBRIDGE_CONTRACT_1INCH_UNIVERSALSWAPANDBRIDGE;

    // 1inch_SwapAndBridge
    address public immutable POLYGON_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE;

    // UniswapV3_UniversalSwapAndBridge
    address public immutable POLYGON_UNISWAPV3_UNIVERSALSWAPANDBRIDGE_UNISWAPV3_UNIVERSALSWAPANDBRIDGE;

    // UniswapV3_SwapAndBridge
    address public immutable POLYGON_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE;

    // MulticallHandler
    address public immutable POLYGON_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 232 (Chain ID: 232)

    // SpokePool
    address public immutable CHAIN_232_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable CHAIN_232_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 288 (Chain ID: 288)

    // SpokePool
    address public immutable CHAIN_288_SPOKEPOOL_SPOKEPOOL;

    // zkSync Era (Chain ID: 324)

    // SpokePool
    address public immutable ZKSYNC_ERA_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable ZKSYNC_ERA_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 480 (Chain ID: 480)

    // SpokePool
    address public immutable CHAIN_480_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_480_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_480_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 690 (Chain ID: 690)

    // SpokePool
    address public immutable CHAIN_690_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_690_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_690_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 919 (Chain ID: 919)

    // SpokePool
    address public immutable CHAIN_919_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable CHAIN_919_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 1135 (Chain ID: 1135)

    // SpokePool
    address public immutable CHAIN_1135_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_1135_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_1135_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 1301 (Chain ID: 1301)

    // SpokePool
    address public immutable CHAIN_1301_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable CHAIN_1301_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 1868 (Chain ID: 1868)

    // SpokePool
    address public immutable CHAIN_1868_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_1868_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_1868_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 4202 (Chain ID: 4202)

    // SpokePool
    address public immutable CHAIN_4202_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable CHAIN_4202_MULTICALLHANDLER_MULTICALLHANDLER;

    // Base (Chain ID: 8453)

    // SpokePool
    address public immutable BASE_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable BASE_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // 1inch_SwapAndBridge
    address public immutable BASE_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE;

    // UniswapV3_SwapAndBridge
    address public immutable BASE_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE;

    // MulticallHandler
    address public immutable BASE_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 34443 (Chain ID: 34443)

    // SpokePool
    address public immutable CHAIN_34443_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_34443_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_34443_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 37111 (Chain ID: 37111)

    // SpokePool
    address public immutable CHAIN_37111_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable CHAIN_37111_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 41455 (Chain ID: 41455)

    // SpokePool
    address public immutable CHAIN_41455_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_41455_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_41455_MULTICALLHANDLER_MULTICALLHANDLER;

    // Arbitrum One (Chain ID: 42161)

    // SpokePool
    address public immutable ARBITRUM_ONE_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable ARBITRUM_ONE_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // 1inch_SwapAndBridge
    address public immutable ARBITRUM_ONE_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE;

    // UniswapV3_SwapAndBridge
    address public immutable ARBITRUM_ONE_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE;

    // MulticallHandler
    address public immutable ARBITRUM_ONE_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 57073 (Chain ID: 57073)

    // SpokePool
    address public immutable CHAIN_57073_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_57073_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_57073_MULTICALLHANDLER_MULTICALLHANDLER;

    // Linea (Chain ID: 59144)

    // SpokePool
    address public immutable LINEA_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable LINEA_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable LINEA_MULTICALLHANDLER_MULTICALLHANDLER;

    // Polygon Amoy (Chain ID: 80002)

    // PolygonTokenBridger
    address public immutable POLYGON_AMOY_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER;

    // SpokePool
    address public immutable POLYGON_AMOY_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable POLYGON_AMOY_MULTICALLHANDLER_MULTICALLHANDLER;

    // Blast (Chain ID: 81457)

    // SpokePool
    address public immutable BLAST_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable BLAST_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable BLAST_MULTICALLHANDLER_MULTICALLHANDLER;

    // Base Sepolia (Chain ID: 84532)

    // SpokePool
    address public immutable BASE_SEPOLIA_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable BASE_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 129399 (Chain ID: 129399)

    // SpokePool
    address public immutable CHAIN_129399_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_129399_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_129399_MULTICALLHANDLER_MULTICALLHANDLER;

    // Arbitrum Sepolia (Chain ID: 421614)

    // SpokePool
    address public immutable ARBITRUM_SEPOLIA_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable ARBITRUM_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER;

    // Scroll (Chain ID: 534352)

    // SpokePool
    address public immutable SCROLL_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable SCROLL_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable SCROLL_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 7777777 (Chain ID: 7777777)

    // SpokePool
    address public immutable CHAIN_7777777_SPOKEPOOL_SPOKEPOOL;

    // SpokePoolVerifier
    address public immutable CHAIN_7777777_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER;

    // MulticallHandler
    address public immutable CHAIN_7777777_MULTICALLHANDLER_MULTICALLHANDLER;

    // Sepolia (Chain ID: 11155111)

    // DeployEthereumSpokePool.s.sol
    address public immutable SEPOLIA_DEPLOYETHEREUMSPOKEPOOL_ETHEREUM_SPOKEPOOL;
    address public immutable SEPOLIA_DEPLOYETHEREUMSPOKEPOOL_ERC1967PROXY;

    // DeployHubPool.s.sol
    address public immutable SEPOLIA_DEPLOYHUBPOOL_LPTOKENFACTORY;
    address public immutable SEPOLIA_DEPLOYHUBPOOL_HUBPOOL;

    // MulticallHandler
    address public immutable SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER;

    // AcrossConfigStore
    address public immutable SEPOLIA_ACROSSCONFIGSTORE_ACROSSCONFIGSTORE;

    // LPTokenFactory
    address public immutable SEPOLIA_LPTOKENFACTORY_LPTOKENFACTORY;

    // HubPool
    address public immutable SEPOLIA_HUBPOOL_HUBPOOL;

    // SpokePool
    address public immutable SEPOLIA_SPOKEPOOL_SPOKEPOOL;

    // PolygonTokenBridger
    address public immutable SEPOLIA_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER;

    // Polygon_Adapter
    address public immutable SEPOLIA_POLYGON_ADAPTER_POLYGON_ADAPTER;

    // Lisk_Adapter
    address public immutable SEPOLIA_LISK_ADAPTER_LISK_ADAPTER;

    // Lens_Adapter
    address public immutable SEPOLIA_LENS_ADAPTER_LENS_ADAPTER;

    // Blast_Adapter
    address public immutable SEPOLIA_BLAST_ADAPTER_BLAST_ADAPTER;

    // DoctorWho_Adapter
    address public immutable SEPOLIA_DOCTORWHO_ADAPTER_DOCTORWHO_ADAPTER;

    // Solana_Adapter
    address public immutable SEPOLIA_SOLANA_ADAPTER_SOLANA_ADAPTER;

    // Optimism Sepolia (Chain ID: 11155420)

    // SpokePool
    address public immutable OPTIMISM_SEPOLIA_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable OPTIMISM_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER;

    // Blast Sepolia (Chain ID: 168587773)

    // SpokePool
    address public immutable BLAST_SEPOLIA_SPOKEPOOL_SPOKEPOOL;

    // MulticallHandler
    address public immutable BLAST_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER;

    // Chain 34268394551451 (Chain ID: 34268394551451)

    // SvmSpoke

    // MulticallHandler

    // MessageTransmitter

    // TokenMessengerMinter

    // Chain 133268194659241 (Chain ID: 133268194659241)

    // SvmSpoke

    // MulticallHandler

    // MessageTransmitter

    // TokenMessengerMinter

    constructor() {
        // Initialize the address mapping
        // Mainnet (Chain ID: 1)
        _addresses[1]["PermissionSplitterProxy"] = 0x0Bf07B2e415F02711fFBB32491f8ec9e5489B2e7;
        _addresses[1]["AcrossConfigStore"] = 0x3B03509645713718B78951126E0A6de6f10043f5;
        _addresses[1]["AcrossMerkleDistributor"] = 0xE50b2cEAC4f60E840Ae513924033E753e2366487;
        _addresses[1]["Arbitrum_Adapter"] = 0x5473CBD30bEd1Bf97C0c9d7c59d268CD620dA426;
        _addresses[1]["Arbitrum_RescueAdapter"] = 0xC6fA0a4EBd802c01157d6E7fB1bbd2ae196ae375;
        _addresses[1]["Arbitrum_SendTokensAdapter"] = 0xC06A68DF12376271817FcEBfb45Be996B0e1593E;
        _addresses[1]["Boba_Adapter"] = 0x33B0Ec794c15D6Cc705818E70d4CaCe7bCfB5Af3;
        _addresses[1]["Ethereum_Adapter"] = 0x527E872a5c3f0C7c24Fe33F2593cFB890a285084;
        _addresses[1]["SpokePool"] = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
        _addresses[1]["HubPool"] = 0xc186fA914353c44b2E33eBE05f21846F1048bEda;
        _addresses[1]["HubPoolStore"] = 0x1Ace3BbD69b63063F859514Eca29C9BDd8310E61;
        _addresses[1]["LpTokenFactory"] = 0x7dB69eb9F52eD773E9b03f5068A1ea0275b2fD9d;
        _addresses[1]["Optimism_Adapter"] = 0xE1e74B3D6A8E2A479B62958D4E4E6eEaea5B612b;
        _addresses[1]["PolygonTokenBridger"] = 0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57;
        _addresses[1]["Polygon_Adapter"] = 0xb4AeF0178f5725392A26eE18684C2aB62adc912e;
        _addresses[1]["ZkSync_Adapter"] = 0xA374585E6062517Ee367ee5044946A6fBe17724f;
        _addresses[1]["Base_Adapter"] = 0xE1421233BF7158A19f89F17c9735F9cbd3D9529c;
        _addresses[1]["Linea_Adapter"] = 0x5A44A32c13e2C43416bFDE5dDF5DCb3880c42787;
        _addresses[1]["BondToken"] = 0xee1DC6BCF1Ee967a350e9aC6CaaAA236109002ea;
        _addresses[1]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[1]["Mode_Adapter"] = 0xf1B59868697f3925b72889ede818B9E7ba0316d0;
        _addresses[1]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        _addresses[1]["Lisk_Adapter"] = 0xF039AdCC74936F90fE175e8b3FE0FdC8b8E0c73b;
        _addresses[1]["Universal_Adapter"] = 0x22001f37B586792F25Ef9d19d99537C6446e0833;
        _addresses[1]["Blast_Adapter"] = 0xF2bEf5E905AAE0295003ab14872F811E914EdD81;
        _addresses[1]["Scroll_Adapter"] = 0x2DA799c2223c6ffB595e578903AE6b95839160d8;
        _addresses[1]["Blast_DaiRetriever"] = 0x98Dd57048d7d5337e92D9102743528ea4Fea64aB;
        _addresses[1]["Blast_RescueAdapter"] = 0xE5Dea263511F5caC27b15cBd58Ff103F4Ce90957;
        _addresses[1]["Redstone_Adapter"] = 0x188F8C95B7cfB7993B53a4F643efa687916f73fA;
        _addresses[1]["Zora_Adapter"] = 0x024F2fC31CBDD8de17194b1892c834f98Ef5169b;
        _addresses[1]["WorldChain_Adapter"] = 0xA8399e221a583A57F54Abb5bA22f31b5D6C09f32;
        _addresses[1]["AlephZero_Adapter"] = 0x6F4083304C2cA99B077ACE06a5DcF670615915Af;
        _addresses[1]["Ink_Adapter"] = 0x7e90A40c7519b041A7DF6498fBf5662e8cFC61d2;
        _addresses[1]["Cher_Adapter"] = 0x0c9d064523177dBB55CFE52b9D0c485FBFc35FD2;
        _addresses[1]["Lens_Adapter"] = 0x63AC22131eD457aeCbD63e6c4C7eeC7BBC74fF1F;
        _addresses[1]["DoctorWho_Adapter"] = 0xFADcC43096756e1527306FD92982FEbBe3c629Fa;
        _addresses[1]["Solana_Adapter"] = 0x1E22A3146439C68A2d247448372AcAEe9E201AB1;

        // Optimism (Chain ID: 10)
        _addresses[10]["SpokePool"] = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
        _addresses[10]["1inch_SwapAndBridge"] = 0x3E7448657409278C9d6E192b92F2b69B234FCc42;
        _addresses[10]["UniswapV3_SwapAndBridge"] = 0x6f4A733c7889f038D77D4f540182Dda17423CcbF;
        _addresses[10]["AcrossMerkleDistributor"] = 0xc8b31410340d57417bE62672f6B53dfB9de30aC2;
        _addresses[10]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[10]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // BSC (Chain ID: 56)
        _addresses[56]["SpokePool"] = 0x4e8E101924eDE233C13e2D8622DC8aED2872d505;
        _addresses[56]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[56]["MulticallHandler"] = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;

        // Chain 130 (Chain ID: 130)
        _addresses[130]["SpokePool"] = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        _addresses[130]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[130]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Polygon (Chain ID: 137)
        _addresses[137]["MintableERC1155"] = 0xA15a90E7936A2F8B70E181E955760860D133e56B;
        _addresses[137]["PolygonTokenBridger"] = 0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57;
        _addresses[137]["SpokePool"] = 0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096;
        _addresses[137]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[137]["1inch_UniversalSwapAndBridge"] = 0xF9735e425A36d22636EF4cb75c7a6c63378290CA;
        _addresses[137]["1inch_SwapAndBridge"] = 0xaBa0F11D55C5dDC52cD0Cb2cd052B621d45159d5;
        _addresses[137]["UniswapV3_UniversalSwapAndBridge"] = 0xC2dCB88873E00c9d401De2CBBa4C6A28f8A6e2c2;
        _addresses[137]["UniswapV3_SwapAndBridge"] = 0x9220Fa27ae680E4e8D9733932128FA73362E0393;
        _addresses[137]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 232 (Chain ID: 232)
        _addresses[232]["SpokePool"] = 0xe7cb3e167e7475dE1331Cf6E0CEb187654619E12;
        _addresses[232]["MulticallHandler"] = 0xc5939F59b3c9662377DdA53A08D5085b2d52b719;

        // Chain 288 (Chain ID: 288)
        _addresses[288]["SpokePool"] = 0xBbc6009fEfFc27ce705322832Cb2068F8C1e0A58;

        // zkSync Era (Chain ID: 324)
        _addresses[324]["SpokePool"] = 0xE0B015E54d54fc84a6cB9B666099c46adE9335FF;
        _addresses[324]["MulticallHandler"] = 0x863859ef502F0Ee9676626ED5B418037252eFeb2;

        // Chain 480 (Chain ID: 480)
        _addresses[480]["SpokePool"] = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        _addresses[480]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[480]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 690 (Chain ID: 690)
        _addresses[690]["SpokePool"] = 0x13fDac9F9b4777705db45291bbFF3c972c6d1d97;
        _addresses[690]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[690]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 919 (Chain ID: 919)
        _addresses[919]["SpokePool"] = 0xbd886FC0725Cc459b55BbFEb3E4278610331f83b;
        _addresses[919]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 1135 (Chain ID: 1135)
        _addresses[1135]["SpokePool"] = 0x9552a0a6624A23B848060AE5901659CDDa1f83f8;
        _addresses[1135]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[1135]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 1301 (Chain ID: 1301)
        _addresses[1301]["SpokePool"] = 0x6999526e507Cc3b03b180BbE05E1Ff938259A874;
        _addresses[1301]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 1868 (Chain ID: 1868)
        _addresses[1868]["SpokePool"] = 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        _addresses[1868]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[1868]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 4202 (Chain ID: 4202)
        _addresses[4202]["SpokePool"] = 0xeF684C38F94F48775959ECf2012D7E864ffb9dd4;
        _addresses[4202]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Base (Chain ID: 8453)
        _addresses[8453]["SpokePool"] = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        _addresses[8453]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[8453]["1inch_SwapAndBridge"] = 0x7CFaBF2eA327009B39f40078011B0Fb714b65926;
        _addresses[8453]["UniswapV3_SwapAndBridge"] = 0xbcfbCE9D92A516e3e7b0762AE218B4194adE34b4;
        _addresses[8453]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 34443 (Chain ID: 34443)
        _addresses[34443]["SpokePool"] = 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        _addresses[34443]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[34443]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 37111 (Chain ID: 37111)
        _addresses[37111]["SpokePool"] = 0x6A0a7f39530923911832Dd60667CE5da5449967B;
        _addresses[37111]["MulticallHandler"] = 0x02D2B95F631E0CF6c203E77f827381B0885F7822;

        // Chain 41455 (Chain ID: 41455)
        _addresses[41455]["SpokePool"] = 0x13fDac9F9b4777705db45291bbFF3c972c6d1d97;
        _addresses[41455]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[41455]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Arbitrum One (Chain ID: 42161)
        _addresses[42161]["SpokePool"] = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
        _addresses[42161]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[42161]["1inch_SwapAndBridge"] = 0xC456398D5eE3B93828252e48beDEDbc39e03368E;
        _addresses[42161]["UniswapV3_SwapAndBridge"] = 0xF633b72A4C2Fb73b77A379bf72864A825aD35b6D;
        _addresses[42161]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 57073 (Chain ID: 57073)
        _addresses[57073]["SpokePool"] = 0xeF684C38F94F48775959ECf2012D7E864ffb9dd4;
        _addresses[57073]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[57073]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Linea (Chain ID: 59144)
        _addresses[59144]["SpokePool"] = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
        _addresses[59144]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[59144]["MulticallHandler"] = 0x1015c58894961F4F7Dd7D68ba033e28Ed3ee1cDB;

        // Polygon Amoy (Chain ID: 80002)
        _addresses[80002]["PolygonTokenBridger"] = 0x4e3737679081c4D3029D88cA560918094f2e0284;
        _addresses[80002]["SpokePool"] = 0xd08baaE74D6d2eAb1F3320B2E1a53eeb391ce8e5;
        _addresses[80002]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Blast (Chain ID: 81457)
        _addresses[81457]["SpokePool"] = 0x2D509190Ed0172ba588407D4c2df918F955Cc6E1;
        _addresses[81457]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[81457]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Base Sepolia (Chain ID: 84532)
        _addresses[84532]["SpokePool"] = 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F;
        _addresses[84532]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 129399 (Chain ID: 129399)
        _addresses[129399]["SpokePool"] = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        _addresses[129399]["SpokePoolVerifier"] = 0x630b76C7cA96164a5aCbC1105f8BA8B739C82570;
        _addresses[129399]["MulticallHandler"] = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;

        // Arbitrum Sepolia (Chain ID: 421614)
        _addresses[421614]["SpokePool"] = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
        _addresses[421614]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Scroll (Chain ID: 534352)
        _addresses[534352]["SpokePool"] = 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        _addresses[534352]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[534352]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 7777777 (Chain ID: 7777777)
        _addresses[7777777]["SpokePool"] = 0x13fDac9F9b4777705db45291bbFF3c972c6d1d97;
        _addresses[7777777]["SpokePoolVerifier"] = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        _addresses[7777777]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Sepolia (Chain ID: 11155111)
        _addresses[11155111]["Ethereum_SpokePool"] = 0xf4883C2DC7FC45eBa7BAF91D2928055D4b14d21B;
        _addresses[11155111]["ERC1967Proxy"] = 0x71f23002439DC6c2dc24F15D573922f8aFd9455A;
        _addresses[11155111]["LpTokenFactory"] = 0x01F4b025f4A12873bbEd3e531dd5aaE6b0B6445A;
        _addresses[11155111]["HubPool"] = 0xFcF9bEF0f97A3A94aD7e5F9E6C97A475DA802016;
        _addresses[11155111]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        _addresses[11155111]["AcrossConfigStore"] = 0xB3De1e212B49e68f4a68b5993f31f63946FCA2a6;
        _addresses[11155111]["LPTokenFactory"] = 0xFB87Ac52Bac7ccF497b6053610A9c59B87a0cE7D;
        _addresses[11155111]["HubPool"] = 0x14224e63716afAcE30C9a417E0542281869f7d9e;
        _addresses[11155111]["SpokePool"] = 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662;
        _addresses[11155111]["PolygonTokenBridger"] = 0x4e3737679081c4D3029D88cA560918094f2e0284;
        _addresses[11155111]["Polygon_Adapter"] = 0x540029039E493b1B843653f93C3064A956931747;
        _addresses[11155111]["Lisk_Adapter"] = 0x13a8B1D6443016424e2b8Bac40dD884Ee679AFc4;
        _addresses[11155111]["Lens_Adapter"] = 0x8fac6F764ae0b4F632FE2E6c938ED5637E629ff2;
        _addresses[11155111]["Blast_Adapter"] = 0x09500Ffd743e01B4146a4BA795231Ca7Ca37819f;
        _addresses[11155111]["DoctorWho_Adapter"] = 0x2b482aFb675e1F231521d5E56770ce4aac592246;
        _addresses[11155111]["Solana_Adapter"] = 0x9b2c2f3fD98cF8468715Be31155cc053C56f822A;

        // Optimism Sepolia (Chain ID: 11155420)
        _addresses[11155420]["SpokePool"] = 0x4e8E101924eDE233C13e2D8622DC8aED2872d505;
        _addresses[11155420]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Blast Sepolia (Chain ID: 168587773)
        _addresses[168587773]["SpokePool"] = 0x5545092553Cf5Bf786e87a87192E902D50D8f022;
        _addresses[168587773]["MulticallHandler"] = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

        // Chain 34268394551451 (Chain ID: 34268394551451)

        // Chain 133268194659241 (Chain ID: 133268194659241)

        // Initialize immutable variables
        MAINNET_DEPLOYPERMISSIONSPLITTERPROXY_PERMISSIONSPLITTERPROXY = 0x0Bf07B2e415F02711fFBB32491f8ec9e5489B2e7;
        MAINNET_ACROSSCONFIGSTORE_ACROSSCONFIGSTORE = 0x3B03509645713718B78951126E0A6de6f10043f5;
        MAINNET_ACROSSMERKLEDISTRIBUTOR_ACROSSMERKLEDISTRIBUTOR = 0xE50b2cEAC4f60E840Ae513924033E753e2366487;
        MAINNET_ARBITRUM_ADAPTER_ARBITRUM_ADAPTER = 0x5473CBD30bEd1Bf97C0c9d7c59d268CD620dA426;
        MAINNET_ARBITRUM_RESCUEADAPTER_ARBITRUM_RESCUEADAPTER = 0xC6fA0a4EBd802c01157d6E7fB1bbd2ae196ae375;
        MAINNET_ARBITRUM_SENDTOKENSADAPTER_ARBITRUM_SENDTOKENSADAPTER = 0xC06A68DF12376271817FcEBfb45Be996B0e1593E;
        MAINNET_BOBA_ADAPTER_BOBA_ADAPTER = 0x33B0Ec794c15D6Cc705818E70d4CaCe7bCfB5Af3;
        MAINNET_ETHEREUM_ADAPTER_ETHEREUM_ADAPTER = 0x527E872a5c3f0C7c24Fe33F2593cFB890a285084;
        MAINNET_SPOKEPOOL_SPOKEPOOL = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
        MAINNET_HUBPOOL_HUBPOOL = 0xc186fA914353c44b2E33eBE05f21846F1048bEda;
        MAINNET_HUBPOOLSTORE_HUBPOOLSTORE = 0x1Ace3BbD69b63063F859514Eca29C9BDd8310E61;
        MAINNET_LPTOKENFACTORY_LPTOKENFACTORY = 0x7dB69eb9F52eD773E9b03f5068A1ea0275b2fD9d;
        MAINNET_OPTIMISM_ADAPTER_OPTIMISM_ADAPTER = 0xE1e74B3D6A8E2A479B62958D4E4E6eEaea5B612b;
        MAINNET_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER = 0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57;
        MAINNET_POLYGON_ADAPTER_POLYGON_ADAPTER = 0xb4AeF0178f5725392A26eE18684C2aB62adc912e;
        MAINNET_ZKSYNC_ADAPTER_ZKSYNC_ADAPTER = 0xA374585E6062517Ee367ee5044946A6fBe17724f;
        MAINNET_BASE_ADAPTER_BASE_ADAPTER = 0xE1421233BF7158A19f89F17c9735F9cbd3D9529c;
        MAINNET_LINEA_ADAPTER_LINEA_ADAPTER = 0x5A44A32c13e2C43416bFDE5dDF5DCb3880c42787;
        MAINNET_BONDTOKEN_BONDTOKEN = 0xee1DC6BCF1Ee967a350e9aC6CaaAA236109002ea;
        MAINNET_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        MAINNET_MODE_ADAPTER_MODE_ADAPTER = 0xf1B59868697f3925b72889ede818B9E7ba0316d0;
        MAINNET_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        MAINNET_LISK_ADAPTER_LISK_ADAPTER = 0xF039AdCC74936F90fE175e8b3FE0FdC8b8E0c73b;
        MAINNET_UNIVERSAL_ADAPTER_UNIVERSAL_ADAPTER = 0x22001f37B586792F25Ef9d19d99537C6446e0833;
        MAINNET_BLAST_ADAPTER_BLAST_ADAPTER = 0xF2bEf5E905AAE0295003ab14872F811E914EdD81;
        MAINNET_SCROLL_ADAPTER_SCROLL_ADAPTER = 0x2DA799c2223c6ffB595e578903AE6b95839160d8;
        MAINNET_BLAST_DAIRETRIEVER_BLAST_DAIRETRIEVER = 0x98Dd57048d7d5337e92D9102743528ea4Fea64aB;
        MAINNET_BLAST_RESCUEADAPTER_BLAST_RESCUEADAPTER = 0xE5Dea263511F5caC27b15cBd58Ff103F4Ce90957;
        MAINNET_REDSTONE_ADAPTER_REDSTONE_ADAPTER = 0x188F8C95B7cfB7993B53a4F643efa687916f73fA;
        MAINNET_ZORA_ADAPTER_ZORA_ADAPTER = 0x024F2fC31CBDD8de17194b1892c834f98Ef5169b;
        MAINNET_WORLDCHAIN_ADAPTER_WORLDCHAIN_ADAPTER = 0xA8399e221a583A57F54Abb5bA22f31b5D6C09f32;
        MAINNET_ALEPHZERO_ADAPTER_ALEPHZERO_ADAPTER = 0x6F4083304C2cA99B077ACE06a5DcF670615915Af;
        MAINNET_INK_ADAPTER_INK_ADAPTER = 0x7e90A40c7519b041A7DF6498fBf5662e8cFC61d2;
        MAINNET_CHER_ADAPTER_CHER_ADAPTER = 0x0c9d064523177dBB55CFE52b9D0c485FBFc35FD2;
        MAINNET_LENS_ADAPTER_LENS_ADAPTER = 0x63AC22131eD457aeCbD63e6c4C7eeC7BBC74fF1F;
        MAINNET_DOCTORWHO_ADAPTER_DOCTORWHO_ADAPTER = 0xFADcC43096756e1527306FD92982FEbBe3c629Fa;
        MAINNET_SOLANA_ADAPTER_SOLANA_ADAPTER = 0x1E22A3146439C68A2d247448372AcAEe9E201AB1;
        OPTIMISM_SPOKEPOOL_SPOKEPOOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
        OPTIMISM_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE = 0x3E7448657409278C9d6E192b92F2b69B234FCc42;
        OPTIMISM_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE = 0x6f4A733c7889f038D77D4f540182Dda17423CcbF;
        OPTIMISM_ACROSSMERKLEDISTRIBUTOR_ACROSSMERKLEDISTRIBUTOR = 0xc8b31410340d57417bE62672f6B53dfB9de30aC2;
        OPTIMISM_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        OPTIMISM_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        BSC_SPOKEPOOL_SPOKEPOOL = 0x4e8E101924eDE233C13e2D8622DC8aED2872d505;
        BSC_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        BSC_MULTICALLHANDLER_MULTICALLHANDLER = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;
        CHAIN_130_SPOKEPOOL_SPOKEPOOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        CHAIN_130_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_130_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        POLYGON_MINTABLEERC1155_MINTABLEERC1155 = 0xA15a90E7936A2F8B70E181E955760860D133e56B;
        POLYGON_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER = 0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57;
        POLYGON_SPOKEPOOL_SPOKEPOOL = 0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096;
        POLYGON_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        POLYGON_1INCH_UNIVERSALSWAPANDBRIDGE_CONTRACT_1INCH_UNIVERSALSWAPANDBRIDGE = 0xF9735e425A36d22636EF4cb75c7a6c63378290CA;
        POLYGON_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE = 0xaBa0F11D55C5dDC52cD0Cb2cd052B621d45159d5;
        POLYGON_UNISWAPV3_UNIVERSALSWAPANDBRIDGE_UNISWAPV3_UNIVERSALSWAPANDBRIDGE = 0xC2dCB88873E00c9d401De2CBBa4C6A28f8A6e2c2;
        POLYGON_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE = 0x9220Fa27ae680E4e8D9733932128FA73362E0393;
        POLYGON_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_232_SPOKEPOOL_SPOKEPOOL = 0xe7cb3e167e7475dE1331Cf6E0CEb187654619E12;
        CHAIN_232_MULTICALLHANDLER_MULTICALLHANDLER = 0xc5939F59b3c9662377DdA53A08D5085b2d52b719;
        CHAIN_288_SPOKEPOOL_SPOKEPOOL = 0xBbc6009fEfFc27ce705322832Cb2068F8C1e0A58;
        ZKSYNC_ERA_SPOKEPOOL_SPOKEPOOL = 0xE0B015E54d54fc84a6cB9B666099c46adE9335FF;
        ZKSYNC_ERA_MULTICALLHANDLER_MULTICALLHANDLER = 0x863859ef502F0Ee9676626ED5B418037252eFeb2;
        CHAIN_480_SPOKEPOOL_SPOKEPOOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        CHAIN_480_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_480_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_690_SPOKEPOOL_SPOKEPOOL = 0x13fDac9F9b4777705db45291bbFF3c972c6d1d97;
        CHAIN_690_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_690_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_919_SPOKEPOOL_SPOKEPOOL = 0xbd886FC0725Cc459b55BbFEb3E4278610331f83b;
        CHAIN_919_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_1135_SPOKEPOOL_SPOKEPOOL = 0x9552a0a6624A23B848060AE5901659CDDa1f83f8;
        CHAIN_1135_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_1135_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_1301_SPOKEPOOL_SPOKEPOOL = 0x6999526e507Cc3b03b180BbE05E1Ff938259A874;
        CHAIN_1301_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_1868_SPOKEPOOL_SPOKEPOOL = 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        CHAIN_1868_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_1868_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_4202_SPOKEPOOL_SPOKEPOOL = 0xeF684C38F94F48775959ECf2012D7E864ffb9dd4;
        CHAIN_4202_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        BASE_SPOKEPOOL_SPOKEPOOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        BASE_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        BASE_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE = 0x7CFaBF2eA327009B39f40078011B0Fb714b65926;
        BASE_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE = 0xbcfbCE9D92A516e3e7b0762AE218B4194adE34b4;
        BASE_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_34443_SPOKEPOOL_SPOKEPOOL = 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        CHAIN_34443_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_34443_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_37111_SPOKEPOOL_SPOKEPOOL = 0x6A0a7f39530923911832Dd60667CE5da5449967B;
        CHAIN_37111_MULTICALLHANDLER_MULTICALLHANDLER = 0x02D2B95F631E0CF6c203E77f827381B0885F7822;
        CHAIN_41455_SPOKEPOOL_SPOKEPOOL = 0x13fDac9F9b4777705db45291bbFF3c972c6d1d97;
        CHAIN_41455_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_41455_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        ARBITRUM_ONE_SPOKEPOOL_SPOKEPOOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
        ARBITRUM_ONE_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        ARBITRUM_ONE_1INCH_SWAPANDBRIDGE_CONTRACT_1INCH_SWAPANDBRIDGE = 0xC456398D5eE3B93828252e48beDEDbc39e03368E;
        ARBITRUM_ONE_UNISWAPV3_SWAPANDBRIDGE_UNISWAPV3_SWAPANDBRIDGE = 0xF633b72A4C2Fb73b77A379bf72864A825aD35b6D;
        ARBITRUM_ONE_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_57073_SPOKEPOOL_SPOKEPOOL = 0xeF684C38F94F48775959ECf2012D7E864ffb9dd4;
        CHAIN_57073_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_57073_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        LINEA_SPOKEPOOL_SPOKEPOOL = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
        LINEA_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        LINEA_MULTICALLHANDLER_MULTICALLHANDLER = 0x1015c58894961F4F7Dd7D68ba033e28Ed3ee1cDB;
        POLYGON_AMOY_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER = 0x4e3737679081c4D3029D88cA560918094f2e0284;
        POLYGON_AMOY_SPOKEPOOL_SPOKEPOOL = 0xd08baaE74D6d2eAb1F3320B2E1a53eeb391ce8e5;
        POLYGON_AMOY_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        BLAST_SPOKEPOOL_SPOKEPOOL = 0x2D509190Ed0172ba588407D4c2df918F955Cc6E1;
        BLAST_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        BLAST_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        BASE_SEPOLIA_SPOKEPOOL_SPOKEPOOL = 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F;
        BASE_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_129399_SPOKEPOOL_SPOKEPOOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
        CHAIN_129399_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x630b76C7cA96164a5aCbC1105f8BA8B739C82570;
        CHAIN_129399_MULTICALLHANDLER_MULTICALLHANDLER = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;
        ARBITRUM_SEPOLIA_SPOKEPOOL_SPOKEPOOL = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
        ARBITRUM_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        SCROLL_SPOKEPOOL_SPOKEPOOL = 0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96;
        SCROLL_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        SCROLL_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        CHAIN_7777777_SPOKEPOOL_SPOKEPOOL = 0x13fDac9F9b4777705db45291bbFF3c972c6d1d97;
        CHAIN_7777777_SPOKEPOOLVERIFIER_SPOKEPOOLVERIFIER = 0x3Fb9cED51E968594C87963a371Ed90c39519f65A;
        CHAIN_7777777_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        SEPOLIA_DEPLOYETHEREUMSPOKEPOOL_ETHEREUM_SPOKEPOOL = 0xf4883C2DC7FC45eBa7BAF91D2928055D4b14d21B;
        SEPOLIA_DEPLOYETHEREUMSPOKEPOOL_ERC1967PROXY = 0x71f23002439DC6c2dc24F15D573922f8aFd9455A;
        SEPOLIA_DEPLOYHUBPOOL_LPTOKENFACTORY = 0x01F4b025f4A12873bbEd3e531dd5aaE6b0B6445A;
        SEPOLIA_DEPLOYHUBPOOL_HUBPOOL = 0xFcF9bEF0f97A3A94aD7e5F9E6C97A475DA802016;
        SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        SEPOLIA_ACROSSCONFIGSTORE_ACROSSCONFIGSTORE = 0xB3De1e212B49e68f4a68b5993f31f63946FCA2a6;
        SEPOLIA_LPTOKENFACTORY_LPTOKENFACTORY = 0xFB87Ac52Bac7ccF497b6053610A9c59B87a0cE7D;
        SEPOLIA_HUBPOOL_HUBPOOL = 0x14224e63716afAcE30C9a417E0542281869f7d9e;
        SEPOLIA_SPOKEPOOL_SPOKEPOOL = 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662;
        SEPOLIA_POLYGONTOKENBRIDGER_POLYGONTOKENBRIDGER = 0x4e3737679081c4D3029D88cA560918094f2e0284;
        SEPOLIA_POLYGON_ADAPTER_POLYGON_ADAPTER = 0x540029039E493b1B843653f93C3064A956931747;
        SEPOLIA_LISK_ADAPTER_LISK_ADAPTER = 0x13a8B1D6443016424e2b8Bac40dD884Ee679AFc4;
        SEPOLIA_LENS_ADAPTER_LENS_ADAPTER = 0x8fac6F764ae0b4F632FE2E6c938ED5637E629ff2;
        SEPOLIA_BLAST_ADAPTER_BLAST_ADAPTER = 0x09500Ffd743e01B4146a4BA795231Ca7Ca37819f;
        SEPOLIA_DOCTORWHO_ADAPTER_DOCTORWHO_ADAPTER = 0x2b482aFb675e1F231521d5E56770ce4aac592246;
        SEPOLIA_SOLANA_ADAPTER_SOLANA_ADAPTER = 0x9b2c2f3fD98cF8468715Be31155cc053C56f822A;
        OPTIMISM_SEPOLIA_SPOKEPOOL_SPOKEPOOL = 0x4e8E101924eDE233C13e2D8622DC8aED2872d505;
        OPTIMISM_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        BLAST_SEPOLIA_SPOKEPOOL_SPOKEPOOL = 0x5545092553Cf5Bf786e87a87192E902D50D8f022;
        BLAST_SEPOLIA_MULTICALLHANDLER_MULTICALLHANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    }

    /**
     * @notice Get contract address by chain ID and contract name
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return The contract address
     */
    function getAddress(uint256 chainId, string memory contractName) public view returns (address) {
        return _addresses[chainId][contractName];
    }

    /**
     * @notice Check if a contract exists for the given chain ID and name
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return True if the contract exists, false otherwise
     */
    function hasAddress(uint256 chainId, string memory contractName) public view returns (bool) {
        return _addresses[chainId][contractName] != address(0);
    }
}
