// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { TopUpGateway } from "../../../../contracts/handlers/TopUpGateway.sol";
import { TopUpGatewayInterface } from "../../../../contracts/interfaces/TopUpGatewayInterface.sol";
import { MockPermit2 } from "../../../../contracts/test/MockPermit2.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { IPermit2 } from "../../../../contracts/external/interfaces/IPermit2.sol";

contract PullTarget {
    uint256 public pulled;

    function pullExact(address token, uint256 amount) external {
        MintableERC20(token).transferFrom(msg.sender, address(this), amount);
        pulled += amount;
    }
}

contract TopUpGatewayTest is Test {
    TopUpGateway gateway;
    MockPermit2 permit2;
    MintableERC20 token;
    PullTarget target;

    uint256 relayerPk = 0xB0B;
    address relayer;
    address refundTo;

    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes private constant PERMIT_TRANSFER_FROM_WITNESS_STUB =
        bytes("PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,");

    function setUp() public {
        relayer = vm.addr(relayerPk);
        refundTo = makeAddr("refundTo");

        permit2 = new MockPermit2();
        gateway = new TopUpGateway(IPermit2(address(permit2)));
        token = new MintableERC20("USDC", "USDC", 6);
        target = new PullTarget();

        token.mint(relayer, 1_000_000_000);
        vm.prank(relayer);
        token.approve(address(permit2), type(uint256).max);
    }

    function testExecuteAndRefundWithoutTopup() public {
        token.mint(address(gateway), 100e6);

        TopUpGateway.ExecutionData memory execution = _executionData(
            bytes32(uint256(1)),
            80e6,
            0,
            abi.encodeCall(PullTarget.pullExact, (address(token), 80e6))
        );

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(token), amount: 0 }),
            nonce: 1,
            deadline: block.timestamp + 1 days
        });

        bytes memory permit2Sig = _signPermit2(permit, execution);
        bytes memory message = abi.encode(execution, permit, permit2Sig);

        vm.prank(makeAddr("anyCaller"));
        gateway.handleV3AcrossMessage(address(token), 100e6, relayer, message);

        assertEq(target.pulled(), 80e6);
        assertEq(token.balanceOf(refundTo), 20e6);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function testReplayNonceReverts() public {
        token.mint(address(gateway), 50e6);

        TopUpGateway.ExecutionData memory execution = _executionData(
            bytes32(uint256(2)),
            50e6,
            0,
            abi.encodeCall(PullTarget.pullExact, (address(token), 50e6))
        );

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(token), amount: 0 }),
            nonce: 2,
            deadline: block.timestamp + 1 days
        });

        bytes memory permit2Sig = _signPermit2(permit, execution);
        bytes memory message = abi.encode(execution, permit, permit2Sig);

        gateway.handleV3AcrossMessage(address(token), 50e6, relayer, message);

        vm.expectRevert(TopUpGatewayInterface.NonceAlreadyUsed.selector);
        gateway.handleV3AcrossMessage(address(token), 50e6, relayer, message);
    }

    function testInvalidPermit2SignatureReverts() public {
        token.mint(address(gateway), 50e6);

        TopUpGateway.ExecutionData memory execution = _executionData(
            bytes32(uint256(3)),
            50e6,
            0,
            abi.encodeCall(PullTarget.pullExact, (address(token), 50e6))
        );

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(token), amount: 0 }),
            nonce: 3,
            deadline: block.timestamp + 1 days
        });

        bytes memory badSig = _signPermit2(permit, execution);
        badSig[0] = bytes1(uint8(badSig[0]) ^ 0x01);
        bytes memory message = abi.encode(execution, permit, badSig);

        vm.expectRevert();
        gateway.handleV3AcrossMessage(address(token), 50e6, relayer, message);
    }

    function testTopupWithPermit2() public {
        token.mint(address(gateway), 60e6);

        TopUpGateway.ExecutionData memory execution = _executionData(
            bytes32(uint256(4)),
            100e6,
            50e6,
            abi.encodeCall(PullTarget.pullExact, (address(token), 100e6))
        );

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(token), amount: 40e6 }),
            nonce: 4,
            deadline: block.timestamp + 1 days
        });

        bytes memory permit2Sig = _signPermit2(permit, execution);
        bytes memory message = abi.encode(execution, permit, permit2Sig);

        gateway.handleV3AcrossMessage(address(token), 60e6, relayer, message);

        assertEq(target.pulled(), 100e6);
        assertEq(token.balanceOf(relayer), 1_000_000_000 - 40e6);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function testMissingPermit2SignatureRevertsWhenTopupNeeded() public {
        token.mint(address(gateway), 60e6);

        TopUpGateway.ExecutionData memory execution = _executionData(
            bytes32(uint256(5)),
            100e6,
            50e6,
            abi.encodeCall(PullTarget.pullExact, (address(token), 100e6))
        );

        bytes memory message = abi.encode(execution, _emptyPermit(address(token), 5), bytes(""));

        vm.expectRevert(TopUpGatewayInterface.MissingPermit2Signature.selector);
        gateway.handleV3AcrossMessage(address(token), 60e6, relayer, message);
    }

    function _executionData(
        bytes32 nonce,
        uint256 requiredAmount,
        uint256 topupMax,
        bytes memory callData
    ) internal view returns (TopUpGatewayInterface.ExecutionData memory execution) {
        execution = TopUpGatewayInterface.ExecutionData({
            nonce: nonce,
            deadline: block.timestamp + 1 days,
            inputToken: address(token),
            requiredAmount: requiredAmount,
            relayer: relayer,
            refundTo: refundTo,
            topupMax: topupMax,
            target: address(target),
            value: 0,
            callData: callData
        });
    }

    function _emptyPermit(
        address permitToken,
        uint256 nonce
    ) internal view returns (IPermit2.PermitTransferFrom memory permit) {
        permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: permitToken, amount: 0 }),
            nonce: nonce,
            deadline: block.timestamp + 1 days
        });
    }

    function _signPermit2(
        IPermit2.PermitTransferFrom memory permit,
        TopUpGateway.ExecutionData memory execution
    ) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_FROM_WITNESS_STUB, gateway.PERMIT2_WITNESS_TYPE_STRING())
        );

        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted.token, permit.permitted.amount)
        );

        bytes32 witness = gateway.executionDigest(execution);
        bytes32 dataHash = keccak256(
            abi.encode(typeHash, tokenPermissionsHash, address(gateway), permit.nonce, permit.deadline, witness)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), dataHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(relayerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
