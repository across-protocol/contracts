// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { IOpUSDCBridgeAdapter } from "../../../../contracts/external/interfaces/IOpUSDCBridgeAdapter.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

import { OP_Adapter } from "../../../../contracts/chain-adapters/OP_Adapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";

contract OP_AdapterTest is Test {
    ERC20 l1Usdc;
    WETH9 l1Weth;

    IL1StandardBridge standardBridge;
    IOpUSDCBridgeAdapter opUSDCBridge;
    ITokenMessenger cctpMessenger;

    uint32 constant RECIPIENT_CIRCLE_DOMAIN_ID = 1;

    function setUp() public {
        l1Usdc = new ERC20("l1Usdc", "l1Usdc");
        l1Weth = new WETH9();

        standardBridge = IL1StandardBridge(makeAddr("standardBridge"));
        opUSDCBridge = IOpUSDCBridgeAdapter(makeAddr("opUSDCBridge"));
        cctpMessenger = ITokenMessenger(makeAddr("cctpMessenger"));
    }

    function testUSDCNotSet() public {
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(0)),
            address(0),
            standardBridge,
            IOpUSDCBridgeAdapter(address(0)),
            ITokenMessenger(address(0)),
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testL1UsdcBridgeSet() public {
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(l1Usdc)),
            address(0),
            standardBridge,
            opUSDCBridge,
            ITokenMessenger(address(0)),
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testCctpMessengerSet() public {
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(0)),
            address(0),
            standardBridge,
            IOpUSDCBridgeAdapter(address(0)),
            cctpMessenger,
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testNeitherSet() public {
        vm.expectRevert(OP_Adapter.InvalidBridgeConfig.selector);
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(l1Usdc)),
            address(0),
            standardBridge,
            IOpUSDCBridgeAdapter(address(0)),
            ITokenMessenger(address(0)),
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testBothSet() public {
        vm.expectRevert(OP_Adapter.InvalidBridgeConfig.selector);
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(l1Usdc)),
            address(0),
            standardBridge,
            opUSDCBridge,
            cctpMessenger,
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }
}
