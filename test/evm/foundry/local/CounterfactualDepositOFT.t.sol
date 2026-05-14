// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    CounterfactualDepositOFT,
    OFTDepositParams,
    OFTSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { ChainConfig } from "../../../../contracts/periphery/counterfactual/ChainConfig.sol";
import { OFT_SRC_PERIPHERY_ID, USDC_ID } from "../../../../contracts/periphery/counterfactual/ChainConfigIds.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SponsoredOFTSrcPeriphery that simulates token transfer and records call data
 */
contract MockSponsoredOFTSrcPeriphery {
    using SafeERC20 for IERC20;

    address public immutable TOKEN;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMsgValue;
    uint256 public callCount;

    // Store the full quote for verification
    uint32 public lastSrcEid;
    uint32 public lastDstEid;
    bytes32 public lastDestinationHandler;
    address public lastRefundRecipient;

    constructor(address _token) {
        TOKEN = _token;
    }

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
        // Pull tokens from caller (same as real SponsoredOFTSrcPeriphery)
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
        lastMsgValue = msg.value;
        lastAmount = quote.signedParams.amountLD;
        lastNonce = quote.signedParams.nonce;
        lastSrcEid = quote.signedParams.srcEid;
        lastDstEid = quote.signedParams.dstEid;
        lastDestinationHandler = quote.signedParams.destinationHandler;
        lastRefundRecipient = quote.unsignedParams.refundRecipient;
        callCount++;
    }

    receive() external payable {}
}

contract CounterfactualOFTDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositOFT public oftImpl;
    WithdrawImplementation public withdrawImpl;
    MockSponsoredOFTSrcPeriphery public srcPeriphery;
    MintableERC20 public token;
    ChainConfig public registry;
    Merkle public merkle;

    address public admin;
    address public user;
    address public relayer;
    address public registryOwner;
    uint256 public signerPrivateKey;
    address public signerAddr;

    uint32 public constant SRC_EID = 30101; // Ethereum LZ eid
    uint32 public constant DST_EID = 30284; // Example destination eid
    bytes32 public finalRecipient;

    OFTDepositParams internal defaultDepositParams;
    WithdrawParams internal withdrawParamsVal;

    // EIP-712 constants — must match contract.
    bytes32 constant EXECUTE_OFT_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteOFTDeposit(uint32 tokenId,uint256 amount,uint256 executionFee,bytes32 nonce,uint256 oftDeadline,uint32 signatureDeadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositOFT");
    bytes32 constant VERSION_HASH = keccak256("v1.0.0");

    /// @dev Absolute execution fee the signer authorizes in the default test setup.
    uint256 constant EXEC_FEE = 1e6;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        registryOwner = makeAddr("registryOwner");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));

        token = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredOFTSrcPeriphery(address(token));
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();

        uint32[] memory bridgeIds = new uint32[](1);
        bridgeIds[0] = OFT_SRC_PERIPHERY_ID;
        address[] memory bridgeAddrs = new address[](1);
        bridgeAddrs[0] = address(srcPeriphery);
        uint32[] memory tokenIds = new uint32[](1);
        tokenIds[0] = USDC_ID;
        address[] memory tokenAddrs = new address[](1);
        tokenAddrs[0] = address(token);
        registry = new ChainConfig(registryOwner, bridgeIds, bridgeAddrs, tokenIds, tokenAddrs, 0, SRC_EID, signerAddr);

        oftImpl = new CounterfactualDepositOFT(address(registry));
        withdrawImpl = new WithdrawImplementation();
        merkle = new Merkle();

        token.mint(user, 1000e6);

        defaultDepositParams = OFTDepositParams({
            dstEid: DST_EID,
            destinationHandler: bytes32(uint256(uint160(makeAddr("composer")))),
            tokenId: USDC_ID,
            maxOftFeeBps: 100,
            lzReceiveGasLimit: 200000,
            lzComposeGasLimit: 500000,
            maxBpsToSponsor: 500,
            maxUserSlippageBps: 50,
            finalRecipient: finalRecipient,
            finalToken: bytes32(uint256(uint160(address(token)))),
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            refundRecipient: makeAddr("refundRecipient"),
            actionData: "",
            maxExecutionFeeBps: 100
        });

        withdrawParamsVal = WithdrawParams({ admin: admin, user: user });
    }

    // --- Merkle helpers ---

    function _leaf(address impl, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(impl, keccak256(params)))));
    }

    /// @dev Build a 4-leaf merkle tree: [OFT deposit, withdraw, padding-a, padding-b].
    function _defaultLeaves() internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](4);
        leaves[0] = _leaf(address(oftImpl), abi.encode(defaultDepositParams));
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(withdrawParamsVal));
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");
    }

    function _merkleRoot() internal view returns (bytes32) {
        return merkle.getRoot(_defaultLeaves());
    }

    function _depositProof() internal view returns (bytes32[] memory) {
        return merkle.getProof(_defaultLeaves(), 0);
    }

    function _withdrawProof() internal view returns (bytes32[] memory) {
        return merkle.getProof(_defaultLeaves(), 1);
    }

    function _encodeWithdrawSubmitterData(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encode(tokenAddr, to, amount);
    }

    // -- EIP-712 helpers --

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signOftDeposit(
        address clone,
        uint32 tokenId,
        uint256 amount,
        uint256 executionFee,
        bytes32 nonce,
        uint256 oftDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_OFT_DEPOSIT_TYPEHASH,
                tokenId,
                amount,
                executionFee,
                nonce,
                oftDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildSubmitterData(
        address clone,
        uint32 tokenId,
        uint256 amount,
        uint256 executionFee,
        bytes32 nonce,
        uint256 oftDeadline,
        uint32 signatureDeadline,
        bytes memory peripherySignature
    ) internal view returns (bytes memory) {
        bytes memory localSig = _signOftDeposit(
            clone,
            tokenId,
            amount,
            executionFee,
            nonce,
            oftDeadline,
            signatureDeadline
        );
        return
            abi.encode(
                OFTSubmitterData({
                    amount: amount,
                    executionFee: executionFee,
                    executionFeeRecipient: relayer,
                    nonce: nonce,
                    oftDeadline: oftDeadline,
                    signatureDeadline: signatureDeadline,
                    signature: localSig,
                    peripherySignature: peripherySignature
                })
            );
    }

    /// @dev Convenience wrapper: signs for `EXEC_FEE` and reuses the
    ///      OFT deadline as the signature deadline.
    function _defaultSubmitterData(
        address clone,
        uint256 amount,
        bytes32 nonce,
        uint256 oftDeadline
    ) internal view returns (bytes memory) {
        return
            _buildSubmitterData(
                clone,
                defaultDepositParams.tokenId,
                amount,
                EXEC_FEE,
                nonce,
                oftDeadline,
                uint32(oftDeadline),
                bytes("peripherySig")
            );
    }

    // --- Tests ---

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 root = _merkleRoot();

        address predicted = factory.predictDepositAddress(address(dispatcher), root, salt);
        address deployed = factory.deploy(address(dispatcher), root, salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - EXEC_FEE;

        bytes32 root = _merkleRoot();
        address depositAddress = factory.predictDepositAddress(address(dispatcher), root, salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.expectEmit(true, true, true, true);
        emit CounterfactualDepositOFT.OFTDepositExecuted(amount, EXEC_FEE, relayer, nonce, block.timestamp + 1 hours);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _defaultSubmitterData(depositAddress, amount, nonce, block.timestamp + 1 hours),
                _depositProof()
            )
        );

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        address deployed = factory.deployAndExecute{ value: 0.1 ether }(
            address(dispatcher),
            root,
            salt,
            executeCalldata
        );

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(token.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(token.balanceOf(relayer), EXEC_FEE, "Relayer should receive execution fee");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
        assertEq(srcPeriphery.lastNonce(), nonce, "SrcPeriphery should have received correct nonce");
    }

    function testMsgValueForwarded() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.05 ether;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute{ value: lzFee }(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _defaultSubmitterData(depositAddress, amount, keccak256("nonce-1"), block.timestamp + 1 hours),
            _depositProof()
        );

        assertEq(srcPeriphery.lastMsgValue(), lzFee, "msg.value should be forwarded to SrcPeriphery");
    }

    function testQuoteParamsBuiltCorrectly() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - EXEC_FEE;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _defaultSubmitterData(depositAddress, amount, keccak256("nonce-1"), block.timestamp + 1 hours),
            _depositProof()
        );

        assertEq(srcPeriphery.lastSrcEid(), SRC_EID, "srcEid should match");
        assertEq(srcPeriphery.lastDstEid(), DST_EID, "dstEid should match");
        assertEq(
            srcPeriphery.lastDestinationHandler(),
            defaultDepositParams.destinationHandler,
            "destinationHandler should match"
        );
        assertEq(
            srcPeriphery.lastRefundRecipient(),
            defaultDepositParams.refundRecipient,
            "refundRecipient should match route immutable"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "amountLD should be net of execution fee");
    }

    function testExecuteOnExistingClone() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        // First deposit
        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _defaultSubmitterData(depositAddress, 100e6, keccak256("nonce-1"), block.timestamp + 1 hours),
            _depositProof()
        );

        // Second deposit
        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _defaultSubmitterData(depositAddress, 100e6, keccak256("nonce-2"), block.timestamp + 1 hours),
            _depositProof()
        );

        assertEq(srcPeriphery.callCount(), 2, "Should have two deposits");
        assertEq(token.balanceOf(depositAddress), 0, "All tokens should be deposited");
        assertEq(token.balanceOf(relayer), 2 * EXEC_FEE, "Relayer should receive fees from both deposits");
    }

    function testExecuteViaFactory() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - EXEC_FEE;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _defaultSubmitterData(depositAddress, amount, keccak256("nonce-1"), block.timestamp + 1 hours),
                _depositProof()
            )
        );

        vm.prank(relayer);
        factory.execute(depositAddress, executeCalldata);

        assertEq(token.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(token.balanceOf(relayer), EXEC_FEE, "Relayer should receive execution fee");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
    }

    function testExecuteViaFactoryForwardsMsgValue() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.05 ether;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _defaultSubmitterData(depositAddress, amount, keccak256("nonce-1"), block.timestamp + 1 hours),
                _depositProof()
            )
        );

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        factory.execute{ value: lzFee }(depositAddress, executeCalldata);

        assertEq(srcPeriphery.lastMsgValue(), lzFee, "msg.value should be forwarded through factory");
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);
        bytes32[] memory proof = _withdrawProof();

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), user, 100e6),
            proof
        );

        assertEq(token.balanceOf(user), 1000e6, "User should have all tokens back");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);
        bytes32[] memory proof = _withdrawProof();

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), relayer, 100e6),
            proof
        );
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);
        bytes32[] memory proof = _withdrawProof();

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(wrongToken), admin, 100e18);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(wrongToken), admin, 100e18),
            proof
        );

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);
        bytes32[] memory proof = _withdrawProof();

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), relayer, 100e6),
            proof
        );
    }

    function testExecuteWithZeroExecutionFee() public {
        OFTDepositParams memory zeroFeeParams = defaultDepositParams;
        zeroFeeParams.maxExecutionFeeBps = 0;

        // Build a new merkle tree with the zero-fee deposit params.
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(oftImpl), abi.encode(zeroFeeParams));
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(withdrawParamsVal));
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 amount = 100e6;

        address depositAddress = factory.deploy(address(dispatcher), root, salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        // Submitter claims 0 execution fee (matches the leaf cap of 0).
        bytes memory submitterData = _buildSubmitterData(
            depositAddress,
            zeroFeeParams.tokenId,
            amount,
            0,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            uint32(block.timestamp + 1 hours),
            bytes("peripherySig")
        );

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(zeroFeeParams),
            submitterData,
            proof
        );

        assertEq(token.balanceOf(relayer), 0, "Relayer should receive no fee");
        assertEq(srcPeriphery.lastAmount(), amount, "Full amount should be deposited");
    }

    function testInvalidProofReverts() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);
        bytes32[] memory proof = _depositProof();

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        // Tamper with the deposit params so the leaf doesn't match the proof.
        OFTDepositParams memory wrongParams = defaultDepositParams;
        wrongParams.maxOftFeeBps = 200;

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(wrongParams),
            _defaultSubmitterData(depositAddress, 100e6, keccak256("nonce-1"), block.timestamp + 1 hours),
            proof
        );
    }

    function testInvalidProofWrongImplementation() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);
        bytes32[] memory proof = _withdrawProof();

        // Use the withdraw proof but with the OFT implementation address -- proof won't match.
        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), user, 100e6),
            proof
        );
    }

    function testRegistryUnsetBridgeReverts() public {
        bytes32 salt = keccak256("oft-unset-bridge");
        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        // Precompute proof and submitter data so the foundry cheats below apply to the right call.
        bytes32[] memory proof = _depositProof();
        bytes memory params = abi.encode(defaultDepositParams);
        bytes memory submitterData = _defaultSubmitterData(
            depositAddress,
            100e6,
            keccak256("nonce"),
            block.timestamp + 1 hours
        );

        vm.prank(registryOwner);
        registry.setBridge(OFT_SRC_PERIPHERY_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(CounterfactualDepositOFT.RegistryUnset.selector, OFT_SRC_PERIPHERY_ID));
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(oftImpl), params, submitterData, proof);
    }

    function testRegistryUnsetTokenReverts() public {
        bytes32 salt = keccak256("oft-unset-token");
        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        bytes32[] memory proof = _depositProof();
        bytes memory params = abi.encode(defaultDepositParams);
        bytes memory submitterData = _defaultSubmitterData(
            depositAddress,
            100e6,
            keccak256("nonce"),
            block.timestamp + 1 hours
        );

        vm.prank(registryOwner);
        registry.setToken(USDC_ID, address(0));

        vm.expectRevert(abi.encodeWithSelector(CounterfactualDepositOFT.RegistryUnset.selector, USDC_ID));
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(oftImpl), params, submitterData, proof);
    }

    function testDeployIfNeededAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - EXEC_FEE;

        bytes32 root = _merkleRoot();
        address depositAddress = factory.predictDepositAddress(address(dispatcher), root, salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _defaultSubmitterData(depositAddress, amount, keccak256("nonce-1"), block.timestamp + 1 hours),
                _depositProof()
            )
        );

        // First call deploys and executes
        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(address(dispatcher), root, salt, executeCalldata);
        assertEq(deployed, depositAddress, "Should return predicted address");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "First deposit should execute");

        // Second call with clone already deployed -- should not revert
        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata2 = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _defaultSubmitterData(depositAddress, amount, keccak256("nonce-2"), block.timestamp + 1 hours),
                _depositProof()
            )
        );

        vm.prank(relayer);
        address deployed2 = factory.deployIfNeededAndExecute(address(dispatcher), root, salt, executeCalldata2);
        assertEq(deployed2, depositAddress, "Should return same address");
        assertEq(srcPeriphery.callCount(), 2, "Both deposits should execute");
    }

    // --- Dynamic execution fee ---

    function testExecutionFeeAboveMaxReverts() public {
        bytes32 salt = keccak256("oft-fee-too-high");
        uint256 amount = 100e6;
        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes32[] memory proof = _depositProof();
        bytes memory params = abi.encode(defaultDepositParams);
        bytes memory submitterData = _buildSubmitterData(
            depositAddress,
            defaultDepositParams.tokenId,
            amount,
            EXEC_FEE + 1,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            uint32(block.timestamp + 1 hours),
            bytes("peripherySig")
        );

        vm.expectRevert(CounterfactualDepositOFT.ExecutionFeeTooHigh.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(oftImpl), params, submitterData, proof);
    }

    function testExecutionFeeMismatchSigFails() public {
        bytes32 salt = keccak256("oft-fee-sig-mismatch");
        uint256 amount = 100e6;
        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes32[] memory proof = _depositProof();
        bytes memory params = abi.encode(defaultDepositParams);

        // Sign for 0.5e6 but submit 1e6 (within the cap).
        bytes memory sig = _signOftDeposit(
            depositAddress,
            defaultDepositParams.tokenId,
            amount,
            0.5e6,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            uint32(block.timestamp + 1 hours)
        );
        bytes memory submitterData = abi.encode(
            OFTSubmitterData({
                amount: amount,
                executionFee: 1e6,
                executionFeeRecipient: relayer,
                nonce: keccak256("nonce"),
                oftDeadline: block.timestamp + 1 hours,
                signatureDeadline: uint32(block.timestamp + 1 hours),
                signature: sig,
                peripherySignature: bytes("peripherySig")
            })
        );

        vm.expectRevert(CounterfactualDepositOFT.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(oftImpl), params, submitterData, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes32 salt = keccak256("oft-sig-expired");
        uint256 amount = 100e6;
        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes32[] memory proof = _depositProof();
        bytes memory params = abi.encode(defaultDepositParams);
        uint32 signatureDeadline = uint32(block.timestamp + 60);
        bytes memory submitterData = _buildSubmitterData(
            depositAddress,
            defaultDepositParams.tokenId,
            amount,
            EXEC_FEE,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            signatureDeadline,
            bytes("peripherySig")
        );

        vm.warp(uint256(signatureDeadline) + 1);

        vm.expectRevert(CounterfactualDepositOFT.SignatureExpired.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(oftImpl), params, submitterData, proof);
    }
}
