// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { Arbitrum_WithdrawalHelper } from "../../../../contracts/chain-adapters/l2/Arbitrum_WithdrawalHelper.sol";
import { Ovm_WithdrawalHelper, IOvm_SpokePool } from "../../../../contracts/chain-adapters/l2/Ovm_WithdrawalHelper.sol";
import { CircleDomainIds } from "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import { L2GatewayRouter } from "../../../../contracts/test/ArbitrumMocks.sol";
import { MockBedrockL2StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../contracts/test/MockBedrockStandardBridge.sol";
import { Base_SpokePool } from "../../../../contracts/Base_SpokePool.sol";
import { Ovm_SpokePool } from "../../../../contracts/Ovm_SpokePool.sol";
import { WithdrawalHelperBase } from "../../../../contracts/chain-adapters/l2/WithdrawalHelperBase.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";

contract Token_ERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

contract WithdrawalAdapterTest is Test {
    uint32 constant fillDeadlineBuffer = type(uint32).max;
    Arbitrum_WithdrawalHelper arbitrumWithdrawalHelper;
    Ovm_WithdrawalHelper ovmWithdrawalHelper;
    Base_SpokePool ovmSpokePool;

    L2GatewayRouter arbBridge;
    MockBedrockL2StandardBridge ovmBridge;
    MockBedrockL2StandardBridge customOvmBridge;
    MockBedrockCrossDomainMessenger messenger;

    Token_ERC20 l1Token;
    Token_ERC20 l2Token;
    Token_ERC20 l1CustomToken;
    Token_ERC20 l2CustomToken;
    Token_ERC20 l2Usdc;
    WETH9 l2Weth;

    // HubPool should receive funds.
    address hubPool;
    // Owner of the Ovm_SpokePool.
    address owner;

    // Token messenger is set so CCTP is activated, but it will contain no contract code.
    ITokenMessenger tokenMessenger;

    function setUp() public {
        // Instantiate addresses.
        l1Token = new Token_ERC20("TOKEN", "TOKEN");
        l2Token = new Token_ERC20("TOKEN", "TOKEN");
        l1CustomToken = new Token_ERC20("CTOKEN", "CTOKEN");
        l2CustomToken = new Token_ERC20("CTOKEN", "CTOKEN");
        l2Usdc = new Token_ERC20("USDC", "USDC");
        l2Weth = new WETH9();

        arbBridge = new L2GatewayRouter();
        customOvmBridge = new MockBedrockL2StandardBridge();

        // The Ovm spoke pools use predeploys in their code, so we must deploy mock code to these addresses.
        deployCodeTo(
            "contracts/test/MockBedrockStandardBridge.sol:MockBedrockL2StandardBridge",
            Lib_PredeployAddresses.L2_STANDARD_BRIDGE
        );
        deployCodeTo(
            "contracts/test/MockBedrockStandardBridge.sol:MockBedrockCrossDomainMessenger",
            Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER
        );
        messenger = MockBedrockCrossDomainMessenger(payable(Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER));
        ovmBridge = MockBedrockL2StandardBridge(payable(Lib_PredeployAddresses.L2_STANDARD_BRIDGE));

        tokenMessenger = ITokenMessenger(makeAddr("tokenMessenger"));
        hubPool = makeAddr("hubPool");
        owner = makeAddr("owner");

        // Construct the Ovm_SpokePool
        vm.startPrank(owner);
        arbBridge.setL2TokenAddress(address(l1Token), address(l2Token));
        Base_SpokePool implementation = new Base_SpokePool(
            address(l2Weth),
            fillDeadlineBuffer,
            fillDeadlineBuffer,
            l2Usdc,
            tokenMessenger
        );
        address proxy = address(
            // The cross domain admin is set as the messenger so that we may set remote token mappings.
            new ERC1967Proxy(address(implementation), abi.encodeCall(Base_SpokePool.initialize, (0, hubPool, owner)))
        );
        ovmSpokePool = Base_SpokePool(payable(proxy));
        vm.stopPrank();

        // Set a custom token and bridge mapping in the spoke pool.
        vm.startPrank(hubPool);
        messenger.impersonateCall(
            address(ovmSpokePool),
            abi.encodeCall(Ovm_SpokePool.setRemoteL1Token, (address(l2CustomToken), address(l1CustomToken)))
        );
        messenger.impersonateCall(
            address(ovmSpokePool),
            abi.encodeCall(Ovm_SpokePool.setTokenBridge, (address(l2CustomToken), address(customOvmBridge)))
        );
        vm.stopPrank();

        arbitrumWithdrawalHelper = new Arbitrum_WithdrawalHelper(
            l2Usdc,
            tokenMessenger,
            WETH9Interface(address(l2Weth)),
            CircleDomainIds.Ethereum,
            address(arbBridge),
            hubPool
        );
        proxy = address(
            new ERC1967Proxy(
                address(arbitrumWithdrawalHelper),
                abi.encodeCall(Ovm_WithdrawalHelper.initialize, (hubPool))
            )
        );
        arbitrumWithdrawalHelper = Arbitrum_WithdrawalHelper(payable(proxy));

        ovmWithdrawalHelper = new Ovm_WithdrawalHelper(
            l2Usdc,
            tokenMessenger,
            WETH9Interface(address(l2Weth)),
            CircleDomainIds.Ethereum,
            address(ovmBridge),
            hubPool,
            IOvm_SpokePool(address(ovmSpokePool))
        );
        proxy = address(
            new ERC1967Proxy(address(ovmWithdrawalHelper), abi.encodeCall(Ovm_WithdrawalHelper.initialize, (hubPool)))
        );
        ovmWithdrawalHelper = Ovm_WithdrawalHelper(payable(proxy));
    }

    // This test should call the gateway router contract.
    function testWithdrawTokenArbitrum(uint256 amountToReturn) public {
        l2Token.mint(address(arbitrumWithdrawalHelper), amountToReturn);

        vm.expectEmit(address(arbBridge));
        emit L2GatewayRouter.OutboundTransfer(address(l1Token), hubPool, amountToReturn);
        arbitrumWithdrawalHelper.withdrawToken(address(l1Token), address(l2Token), amountToReturn);
    }

    // This test should error since the token mappings are incorrect.
    function testWithdrawInvalidTokenArbitrum(uint256 amountToReturn, address invalidToken) public {
        vm.assume(invalidToken != address(l1Token));
        l2Token.mint(address(arbitrumWithdrawalHelper), amountToReturn);

        vm.expectRevert(Arbitrum_WithdrawalHelper.InvalidTokenMapping.selector);
        arbitrumWithdrawalHelper.withdrawToken(invalidToken, address(l2Token), amountToReturn);
    }

    // This test should call the OpStack standard bridge with l2Eth as the input token.
    function testWithdrawEthOvm(uint256 amountToReturn, address random) public {
        // Give the withdrawal adapter some ETH. The contract should automatically swap it into WETH.
        vm.startPrank(random);
        vm.deal(random, amountToReturn);
        (bool success, ) = address(ovmWithdrawalHelper).call{ value: amountToReturn }("");
        require(success, "Withdrawal Helper failed to receive ETH");
        vm.stopPrank();

        vm.expectEmit(address(ovmBridge));
        emit MockBedrockL2StandardBridge.ERC20WithdrawalInitiated(
            Lib_PredeployAddresses.OVM_ETH,
            hubPool,
            amountToReturn
        );
        ovmWithdrawalHelper.withdrawToken(random, address(l2Weth), amountToReturn);
    }

    // This test should call the OpStack standard bridge with l2Token as the input token. `withdrawTo` should be called.
    function testWithdrawTokenOvm(uint256 amountToReturn) public {
        l2Token.mint(address(arbitrumWithdrawalHelper), amountToReturn);

        vm.expectEmit(address(ovmBridge));
        emit MockBedrockL2StandardBridge.ERC20WithdrawalInitiated(address(l2Token), hubPool, amountToReturn);
        ovmWithdrawalHelper.withdrawToken(address(l1Token), address(l2Token), amountToReturn);
    }

    // This test should use a custom token bridge with a custom l1/l2 token mapping. `bridgeERC20To` should be called.
    function testWithdrawCustomMappingsOvm(uint256 amountToReturn) public {
        l2CustomToken.mint(address(ovmWithdrawalHelper), amountToReturn);
        l1CustomToken.mint(address(customOvmBridge), amountToReturn);
        assertEq(0, l1CustomToken.balanceOf(hubPool));
        assertEq(0, l2CustomToken.balanceOf(hubPool));
        assertEq(amountToReturn, l2CustomToken.balanceOf(address(ovmWithdrawalHelper)));

        ovmWithdrawalHelper.withdrawToken(address(l1CustomToken), address(l2CustomToken), amountToReturn);

        assertEq(amountToReturn, l1CustomToken.balanceOf(hubPool));
        assertEq(0, l2CustomToken.balanceOf(hubPool));
        assertEq(0, l2CustomToken.balanceOf(address(ovmWithdrawalHelper)));
    }

    function testUpgrade(uint256 amountToReturn, address rando) public {
        vm.assume(rando != hubPool);
        l2CustomToken.mint(address(ovmWithdrawalHelper), amountToReturn);

        address newImplementation = address(
            new Arbitrum_WithdrawalHelper(
                l2Usdc,
                tokenMessenger,
                WETH9Interface(address(l2Weth)),
                CircleDomainIds.Ethereum,
                address(arbBridge),
                hubPool
            )
        );

        // Should revert if we are an unauthorized user.
        vm.startPrank(rando);
        vm.expectRevert(WithdrawalHelperBase.NotCrossDomainAdmin.selector);
        messenger.impersonateCall(
            address(ovmWithdrawalHelper),
            abi.encodeCall(UUPSUpgradeable.upgradeTo, (newImplementation))
        );
        vm.stopPrank();

        // Should work if we are an authorized user.
        vm.startPrank(hubPool);
        messenger.impersonateCall(
            address(ovmWithdrawalHelper),
            abi.encodeCall(UUPSUpgradeable.upgradeTo, (newImplementation))
        );
        vm.stopPrank();
    }
}
