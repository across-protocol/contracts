// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositExecutor } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositExecutor.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { ICounterfactualDepositFactory } from "../../../../contracts/interfaces/ICounterfactualDepositFactory.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract CounterfactualDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDepositExecutor public executor;
    MockSpokePool public spokePool;
    MintableERC20 public inputToken;
    MintableERC20 public outputToken;

    address public admin;
    address public quoteSigner;
    uint256 public quoteSignerPk;
    address public user;
    address public relayer;

    uint256 public constant DESTINATION_CHAIN_ID = 10; // Optimism
    bytes32 public recipient;

    function setUp() public {
        // Setup accounts
        admin = makeAddr("admin");
        (quoteSigner, quoteSignerPk) = makeAddrAndKey("quoteSigner");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        recipient = bytes32(uint256(uint160(makeAddr("recipient"))));

        // Deploy tokens
        inputToken = new MintableERC20("Input Token", "IN", 18);
        outputToken = new MintableERC20("Output Token", "OUT", 18);

        // Deploy MockSpokePool with UUPS proxy
        address weth = address(new MintableERC20("WETH", "WETH", 18));
        MockSpokePool implementation = new MockSpokePool(weth);
        bytes memory initData = abi.encodeCall(
            MockSpokePool.initialize,
            (0, address(this), address(this)) // initialDepositId, crossDomainAdmin, hubPool
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        spokePool = MockSpokePool(payable(address(proxy)));

        // Deploy factory and executor (3-step process to break circular dependency)
        factory = new CounterfactualDepositFactory(address(spokePool), admin, quoteSigner);
        executor = new CounterfactualDepositExecutor(address(factory), address(spokePool));
        vm.prank(admin);
        factory.setExecutor(address(executor));

        // Mint tokens to user
        inputToken.mint(user, 1000e18);
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));

        address predicted = factory.predictDepositAddress(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "", // message
            type(uint256).max, // maxGasFee
            10000, // maxCapitalFee (100%)
            salt
        );

        // Verify prediction matches actual deployment
        address deployed = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployEmitsEvent() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.DepositAddressCreated(
            factory.predictDepositAddress(
                inputTokenBytes,
                outputTokenBytes,
                DESTINATION_CHAIN_ID,
                recipient,
                "",
                type(uint256).max,
                10000,
                salt
            ),
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            salt
        );

        factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );
    }

    function testCannotDeployTwice() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));

        // First deployment succeeds
        factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        // Second deployment reverts
        vm.expectRevert();
        factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );
    }

    function testDeployedContractHasCorrectImmutables() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));

        address deployed = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        CounterfactualDeposit depositContract = CounterfactualDeposit(payable(deployed));

        assertEq(depositContract.executor(), address(executor), "Executor address mismatch");
        assertEq(depositContract.inputToken(), inputTokenBytes, "Input token mismatch");
        assertEq(depositContract.outputToken(), outputTokenBytes, "Output token mismatch");
        assertEq(depositContract.destinationChainId(), DESTINATION_CHAIN_ID, "Destination chain ID mismatch");
        assertEq(depositContract.recipient(), recipient, "Recipient mismatch");
    }

    function testVerifyValidSignature() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.predictDepositAddress(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        assertTrue(factory.verifyQuote(quote, signature), "Valid signature should verify");
    }

    function testVerifyInvalidSignature() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.predictDepositAddress(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        // Sign with wrong key
        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        bytes memory wrongSignature = _signQuote(quote, wrongPk);

        assertFalse(factory.verifyQuote(quote, wrongSignature), "Invalid signature should not verify");
    }

    function testDeployAndExecute() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.predictDepositAddress(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        // User sends tokens to deposit address
        vm.prank(user);
        inputToken.transfer(depositAddress, 100e18);

        // Create signed quote
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        // Relayer executes deployAndExecute
        uint256 initialDepositId = spokePool.numberOfDeposits();

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.DepositExecuted(depositAddress, 100e18, 99e18, initialDepositId);

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "", // message
            type(uint256).max, // maxGasFee
            10000, // maxCapitalFee (100%)
            salt,
            quote,
            signature
        );

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(inputToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(spokePool.numberOfDeposits(), initialDepositId + 1, "Deposit ID should increment");
    }

    function testExecuteOnExisting() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        // First deploy
        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        // User sends tokens
        vm.prank(user);
        inputToken.transfer(depositAddress, 100e18);

        // Create and execute first deposit
        ICounterfactualDepositFactory.DepositQuote memory quote1 = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature1 = _signQuote(quote1, quoteSignerPk);

        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote1, signature1);

        // Send more tokens for second deposit
        vm.prank(user);
        inputToken.transfer(depositAddress, 50e18);

        // Create and execute second deposit
        ICounterfactualDepositFactory.DepositQuote memory quote2 = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 50e18,
            outputAmount: 49e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature2 = _signQuote(quote2, quoteSignerPk);

        uint256 depositIdBefore = spokePool.numberOfDeposits();

        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote2, signature2);

        assertEq(spokePool.numberOfDeposits(), depositIdBefore + 1, "Second deposit should increment ID");
        assertEq(inputToken.balanceOf(depositAddress), 0, "All tokens should be deposited");
    }

    function testExecuteWithInsufficientBalance() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        // Send insufficient tokens
        vm.prank(user);
        inputToken.transfer(depositAddress, 50e18);

        // Try to deposit more than balance
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        vm.expectRevert(ICounterfactualDepositFactory.InsufficientBalance.selector);
        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote, signature);
    }

    function testExecuteWithExpiredQuote() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, 100e18);

        // Create quote with past deadline
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp - 1,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        vm.expectRevert(ICounterfactualDepositFactory.QuoteExpired.selector);
        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote, signature);
    }

    function testExecuteWithWrongDepositAddress() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt1 = keccak256("test-salt-1");
        bytes32 salt2 = keccak256("test-salt-2");

        // Deploy two different deposit addresses
        address depositAddress1 = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt1
        );

        address depositAddress2 = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt2
        );

        vm.prank(user);
        inputToken.transfer(depositAddress1, 100e18);

        // Create quote for depositAddress1 but try to execute on depositAddress2
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress1,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 99e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        vm.expectRevert(ICounterfactualDepositFactory.WrongDepositAddress.selector);
        vm.prank(relayer);
        factory.executeOnExisting(depositAddress2, quote, signature);
    }

    function testAdminWithdraw() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        // User sends wrong token
        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        // Admin withdraws
        vm.prank(admin);
        CounterfactualDepositExecutor(depositAddress).adminWithdraw(address(wrongToken), admin, 100e18);

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
        assertEq(wrongToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        vm.expectRevert(ICounterfactualDepositFactory.Unauthorized.selector);
        vm.prank(user);
        CounterfactualDepositExecutor(depositAddress).adminWithdraw(address(inputToken), user, 100e18);
    }

    function testSetQuoteSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.QuoteSignerUpdated(quoteSigner, newSigner);

        vm.prank(admin);
        factory.setQuoteSigner(newSigner);

        assertEq(factory.quoteSigner(), newSigner, "Quote signer should be updated");
    }

    function testSetQuoteSignerUnauthorized() public {
        address newSigner = makeAddr("newSigner");

        vm.expectRevert(ICounterfactualDepositFactory.Unauthorized.selector);
        vm.prank(user);
        factory.setQuoteSigner(newSigner);
    }

    function testSetAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.AdminUpdated(admin, newAdmin);

        vm.prank(admin);
        factory.setAdmin(newAdmin);

        assertEq(factory.admin(), newAdmin, "Admin should be updated");
    }

    function testSetAdminUnauthorized() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectRevert(ICounterfactualDepositFactory.Unauthorized.selector);
        vm.prank(user);
        factory.setAdmin(newAdmin);
    }

    function testSameQuoteMultipleExecutions() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max,
            10000,
            salt
        );

        // Create one quote
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 50e18,
            outputAmount: 49e18,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours), // Within 9 hour buffer
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        // First execution
        vm.prank(user);
        inputToken.transfer(depositAddress, 50e18);

        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote, signature);

        // Second execution with same quote (user adds more tokens)
        vm.prank(user);
        inputToken.transfer(depositAddress, 50e18);

        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote, signature);

        assertEq(spokePool.numberOfDeposits(), 2, "Should have two deposits");
        assertEq(inputToken.balanceOf(depositAddress), 0, "All tokens should be deposited");
    }

    function testGasFeeTooHigh() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        // Deploy with very low maxGasFee (1e18)
        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            1e18, // maxGasFee - very low
            10000, // maxCapitalFee (100%)
            salt
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, 100e18);

        // Create quote with fee of 2e18 (exceeds maxGasFee)
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 98e18, // Fee = 2e18, exceeds maxGasFee
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours),
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        vm.expectRevert(ICounterfactualDepositFactory.GasFeeTooHigh.selector);
        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote, signature);
    }

    function testCapitalFeeTooHigh() public {
        bytes32 inputTokenBytes = bytes32(uint256(uint160(address(inputToken))));
        bytes32 outputTokenBytes = bytes32(uint256(uint160(address(outputToken))));
        bytes32 salt = keccak256("test-salt");

        // Deploy with 1% max capital fee (100 basis points)
        address depositAddress = factory.deploy(
            inputTokenBytes,
            outputTokenBytes,
            DESTINATION_CHAIN_ID,
            recipient,
            "",
            type(uint256).max, // maxGasFee - unlimited
            100, // maxCapitalFee - 1%
            salt
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, 100e18);

        // Create quote with 2% fee (exceeds maxCapitalFee of 1%)
        ICounterfactualDepositFactory.DepositQuote memory quote = ICounterfactualDepositFactory.DepositQuote({
            depositAddress: depositAddress,
            deadline: block.timestamp + 1 hours,
            inputAmount: 100e18,
            outputAmount: 98e18, // Fee = 2e18 = 2%, exceeds maxCapitalFee of 1%
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 4 hours),
            exclusivityParameter: 0,
            exclusiveRelayer: bytes32(0)
        });

        bytes memory signature = _signQuote(quote, quoteSignerPk);

        vm.expectRevert(ICounterfactualDepositFactory.GasFeeTooHigh.selector);
        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, quote, signature);
    }

    // Helper function to sign a quote using EIP-712
    function _signQuote(
        ICounterfactualDepositFactory.DepositQuote memory quote,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        // Hash the struct data
        bytes32 structHash = keccak256(
            abi.encode(
                factory.DEPOSIT_QUOTE_TYPEHASH(),
                quote.depositAddress,
                quote.deadline,
                quote.inputAmount,
                quote.outputAmount,
                quote.quoteTimestamp,
                quote.fillDeadline,
                quote.exclusivityParameter,
                quote.exclusiveRelayer
            )
        );

        // Compute EIP-712 digest using the same formula as OpenZeppelin's _hashTypedDataV4
        bytes32 domainSeparator = _computeDomainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // Helper to compute domain separator (matches OpenZeppelin EIP712)
    function _computeDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("Across Counterfactual Deposit")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(factory)
                )
            );
    }
}
