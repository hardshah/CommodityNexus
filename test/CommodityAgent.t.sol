// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {CommodityAgent} from "../src/CommodityAgent.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockOracle is AggregatorV3Interface {
    int256 public price;
    uint256 public updatedAt;
    uint80 public roundId;

    function setPrice(int256 _price, uint256 _updatedAt) external {
        price = _price;
        updatedAt = _updatedAt;
        roundId++;
    }

    function decimals() external pure override returns (uint8) { return 8; }
    function description() external pure override returns (string memory) { return "XAU/USD"; }
    function version() external pure override returns (uint256) { return 1; }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, roundId);
    }
}

contract MockRouter is IRouterClient {
    uint256 public constant FEE = 1e18;
    bool public forceRevertCcipSend;
    Client.EVM2AnyMessage public lastMessage;
    uint64 public lastDestSelector;
    bytes32 public constant MOCK_MESSAGE_ID = keccak256("mock-ccip-message-id");

    function setForceRevertCcipSend(bool _v) external {
        forceRevertCcipSend = _v;
    }

    function isChainSupported(uint64) external pure override returns (bool) { return true; }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure override returns (uint256) {
        return FEE;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        override
        returns (bytes32)
    {
        if (forceRevertCcipSend) revert("CCIP_SEND_FAILED");
        lastDestSelector = destinationChainSelector;
        lastMessage = message;
        return MOCK_MESSAGE_ID;
    }
}

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function decimals() external pure returns (uint8) { return 18; }
    function name() external pure returns (string memory) { return "Mock"; }
    function symbol() external pure returns (string memory) { return "M"; }
}

contract CommodityAgentHarness is CommodityAgent {
    constructor(
        address router,
        address linkFeeToken,
        uint64 localChainSelector,
        address xauUsdOracle_,
        uint16 oracleDeviationBps_,
        uint32 oracleMaxStalenessSeconds_
    ) CommodityAgent(router, linkFeeToken, localChainSelector, xauUsdOracle_, oracleDeviationBps_, oracleMaxStalenessSeconds_) {}

    function exposed_ccipReceive(Client.Any2EVMMessage memory m) external {
        _ccipReceive(m);
    }
}

contract CommodityAgentTest is Test {
    CommodityAgentHarness public agent;
    MockRouter public router;
    MockOracle public oracle;
    MockERC20 public linkToken;
    MockERC20 public commodityToken;

    uint64 constant LOCAL_SELECTOR = 10344971235874465080;
    uint64 constant DST_SELECTOR = 3478487238524512106;
    uint16 constant DEFAULT_DEVIATION_BPS = 50;
    uint32 constant DEFAULT_STALENESS = 3600;

    address maker;
    address solver1;
    address solver2;
    uint256 makerKey;
    uint256 solver1Key;
    uint256 solver2Key;

    function setUp() public {
        makerKey = 0xa11ce;
        solver1Key = 0xb0b;
        solver2Key = 0xc0c;
        maker = vm.addr(makerKey);
        solver1 = vm.addr(solver1Key);
        solver2 = vm.addr(solver2Key);

        router = new MockRouter();
        oracle = new MockOracle();
        linkToken = new MockERC20();
        commodityToken = new MockERC20();

        oracle.setPrice(2500e8, block.timestamp);
        linkToken.mint(address(this), 1000e18);
        commodityToken.mint(maker, 1000e18);

        agent = new CommodityAgentHarness(
            address(router),
            address(linkToken),
            LOCAL_SELECTOR,
            address(oracle),
            DEFAULT_DEVIATION_BPS,
            DEFAULT_STALENESS
        );

        linkToken.transfer(address(agent), 100e18);
    }

    function _signIntent(CommodityAgent.IntentParams memory p) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                agent.INTENT_TYPEHASH(),
                p.maker,
                p.srcChainSelector,
                p.dstChainSelector,
                p.srcToken,
                p.dstReceiver,
                p.totalAmount,
                p.nonce,
                p.xauUsdRef,
                p.maxOracleDeviationBps,
                p.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, _hashTypedData(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,
        ) = agent.eip712Domain();
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(abi.encode(typeHash, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function test_createIntent_validSignature_opensAuction() public {
        CommodityAgent.IntentParams memory p = CommodityAgent.IntentParams({
            maker: maker,
            srcChainSelector: LOCAL_SELECTOR,
            dstChainSelector: DST_SELECTOR,
            srcToken: address(commodityToken),
            dstReceiver: address(0x123),
            totalAmount: 100e18,
            nonce: 1,
            xauUsdRef: 2500e8,
            maxOracleDeviationBps: 50,
            deadline: uint40(block.timestamp + 600)
        });
        bytes memory sig = _signIntent(p);
        bytes32 intentId = agent.createIntent(p, sig);
        assertTrue(intentId != bytes32(0));
        CommodityAgent.IntentRecord memory rec = agent.getIntent(intentId);
        assertEq(uint256(rec.state), uint256(CommodityAgent.IntentState.AUCTION_OPEN));
        assertEq(rec.params.maker, maker);
        assertEq(rec.params.totalAmount, 100e18);
        assertEq(rec.filledAmount, 0);
        assertEq(rec.auctionClosesAt, rec.auctionOpenedAt + 60);
    }

    function test_createIntent_invalidSignature_reverts() public {
        CommodityAgent.IntentParams memory p = CommodityAgent.IntentParams({
            maker: maker,
            srcChainSelector: LOCAL_SELECTOR,
            dstChainSelector: DST_SELECTOR,
            srcToken: address(commodityToken),
            dstReceiver: address(0x123),
            totalAmount: 100e18,
            nonce: 2,
            xauUsdRef: 2500e8,
            maxOracleDeviationBps: 50,
            deadline: uint40(block.timestamp + 600)
        });
        bytes32 structHash = keccak256(
            abi.encode(
                agent.INTENT_TYPEHASH(),
                p.maker,
                p.srcChainSelector,
                p.dstChainSelector,
                p.srcToken,
                p.dstReceiver,
                p.totalAmount,
                p.nonce,
                p.xauUsdRef,
                p.maxOracleDeviationBps,
                p.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(solver1Key, _hashTypedData(structHash));
        bytes memory wrongSig = abi.encodePacked(r, s, v);
        vm.expectRevert(CommodityAgent.InvalidSignature.selector);
        agent.createIntent(p, wrongSig);
    }

    function test_createIntent_replayProtection_reverts() public {
        CommodityAgent.IntentParams memory p = CommodityAgent.IntentParams({
            maker: maker,
            srcChainSelector: LOCAL_SELECTOR,
            dstChainSelector: DST_SELECTOR,
            srcToken: address(commodityToken),
            dstReceiver: address(0x123),
            totalAmount: 100e18,
            nonce: 3,
            xauUsdRef: 2500e8,
            maxOracleDeviationBps: 50,
            deadline: uint40(block.timestamp + 600)
        });
        bytes memory sig = _signIntent(p);
        agent.createIntent(p, sig);
        vm.expectRevert(CommodityAgent.NonceAlreadyUsed.selector);
        agent.createIntent(p, sig);
    }

    function test_createIntent_zeroAmount_reverts() public {
        CommodityAgent.IntentParams memory p = CommodityAgent.IntentParams({
            maker: maker,
            srcChainSelector: LOCAL_SELECTOR,
            dstChainSelector: DST_SELECTOR,
            srcToken: address(commodityToken),
            dstReceiver: address(0x123),
            totalAmount: 0,
            nonce: 4,
            xauUsdRef: 2500e8,
            maxOracleDeviationBps: 50,
            deadline: uint40(block.timestamp + 600)
        });
        bytes memory sig = _signIntent(p);
        vm.expectRevert(CommodityAgent.InvalidIntentParams.selector);
        agent.createIntent(p, sig);
    }

    function test_submitBid_duplicateBid_reverts() public {
        (, bytes32 intentId) = _createIntentAndAdvance();
        vm.prank(solver1);
        agent.submitBid(intentId, 1e18, 300000);
        vm.prank(solver1);
        vm.expectRevert(CommodityAgent.DuplicateBid.selector);
        agent.submitBid(intentId, 2e18, 300000);
    }

    function test_submitBid_expiredIntent_reverts() public {
        CommodityAgent.IntentParams memory p = CommodityAgent.IntentParams({
            maker: maker,
            srcChainSelector: LOCAL_SELECTOR,
            dstChainSelector: DST_SELECTOR,
            srcToken: address(commodityToken),
            dstReceiver: address(0x123),
            totalAmount: 100e18,
            nonce: 99,
            xauUsdRef: 2500e8,
            maxOracleDeviationBps: 50,
            deadline: uint40(block.timestamp + 30)
        });
        bytes32 intentId = agent.createIntent(p, _signIntent(p));
        vm.warp(block.timestamp + 31);
        vm.prank(solver1);
        vm.expectRevert(CommodityAgent.IntentExpired.selector);
        agent.submitBid(intentId, 1e18, 300000);
    }

    function test_selectBid_beforeAuctionClose_reverts() public {
        (, bytes32 intentId) = _createIntentAndAdvance();
        vm.prank(solver1);
        agent.submitBid(intentId, 1e18, 300000);
        vm.expectRevert(CommodityAgent.AuctionStillOpen.selector);
        agent.selectBid(intentId);
    }

    function test_selectBid_noBids_reverts() public {
        (, bytes32 intentId) = _createIntentAndAdvance();
        vm.warp(block.timestamp + 61);
        vm.expectRevert(CommodityAgent.NoBids.selector);
        agent.selectBid(intentId);
    }

    function test_selectBid_selectsLowestExecutionCost() public {
        (, bytes32 intentId) = _createIntentAndAdvance();
        vm.prank(solver1);
        agent.submitBid(intentId, 3e18, 300000);
        vm.prank(solver2);
        agent.submitBid(intentId, 1e18, 250000);
        vm.warp(block.timestamp + 61);
        vm.expectEmit(true, true, true, true);
        emit CommodityAgent.BidSelected(intentId, solver2, 1e18, 250000);
        agent.selectBid(intentId);
        CommodityAgent.IntentRecord memory rec = agent.getIntent(intentId);
        assertEq(rec.selectedSolver, solver2);
        assertEq(rec.selectedExecutionCost, 1e18);
        assertEq(rec.selectedDstGasLimit, 250000);
    }

    function test_executeIntent_success_setsExecuted_andEmits() public {
        (, bytes32 intentId) = _createIntentSelectAndApprove();
        vm.prank(solver1);
        bytes32 msgId = agent.executeIntent(intentId);
        assertEq(msgId, router.MOCK_MESSAGE_ID());
        CommodityAgent.IntentRecord memory rec = agent.getIntent(intentId);
        assertEq(uint256(rec.state), uint256(CommodityAgent.IntentState.EXECUTED));
        assertEq(rec.filledAmount, 100e18);
    }

    function test_executePartial_success_updatesFilled_andAllowsFinalFill() public {
        (CommodityAgent.IntentParams memory p, bytes32 intentId) = _createIntentSelectAndApprove();
        vm.startPrank(solver1);
        agent.executePartial(intentId, 50e18);
        assertEq(agent.getIntent(intentId).filledAmount, 50e18);
        assertEq(uint256(agent.getIntent(intentId).state), uint256(CommodityAgent.IntentState.BID_SELECTED));
        agent.executeIntent(intentId);
        vm.stopPrank();
        assertEq(agent.getIntent(intentId).filledAmount, 100e18);
        assertEq(uint256(agent.getIntent(intentId).state), uint256(CommodityAgent.IntentState.EXECUTED));
    }

    function test_executePartial_overfill_reverts() public {
        (, bytes32 intentId) = _createIntentSelectAndApprove();
        vm.prank(solver1);
        vm.expectRevert(CommodityAgent.OverFill.selector);
        agent.executePartial(intentId, 101e18);
    }

    function test_executeIntent_oracleDeviation_reverts() public {
        (, bytes32 intentId) = _createIntentSelectAndApprove();
        oracle.setPrice(3000e8, block.timestamp);
        vm.prank(solver1);
        vm.expectRevert(CommodityAgent.OracleDeviation.selector);
        agent.executeIntent(intentId);
    }

    function test_executeIntent_oracleStale_reverts() public {
        (, bytes32 intentId) = _createIntentSelectAndApprove();
        vm.warp(5000);
        oracle.setPrice(2500e8, 1000);
        vm.prank(solver1);
        vm.expectRevert(CommodityAgent.OracleStale.selector);
        agent.executeIntent(intentId);
    }

    function test_executeIntent_ccipSendFailure_revertsAndStateNotExecuted() public {
        (, bytes32 intentId) = _createIntentSelectAndApprove();
        router.setForceRevertCcipSend(true);
        vm.prank(solver1);
        vm.expectRevert();
        agent.executeIntent(intentId);
        assertEq(uint256(agent.getIntent(intentId).state), uint256(CommodityAgent.IntentState.BID_SELECTED));
        assertEq(agent.getIntent(intentId).filledAmount, 0);
    }

    function test__ccipReceive_decodesAndEmitsDestinationExecution() public {
        address dstReceiver = address(0x1234567890123456789012345678901234567890);
        bytes32 intentId = keccak256("test-intent");
        uint256 fillAmount = 50e18;
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("incoming-msg"),
            sourceChainSelector: DST_SELECTOR,
            sender: abi.encode(address(router)),
            data: abi.encode(intentId, fillAmount, dstReceiver),
            destTokenAmounts: tokenAmounts
        });
        vm.prank(address(router));
        vm.expectEmit(true, true, true, true);
        emit CommodityAgent.DestinationExecution(intentId, message.messageId, fillAmount, address(0x1234567890123456789012345678901234567890));
        agent.exposed_ccipReceive(message);
    }

    function _createIntentAndAdvance() internal returns (CommodityAgent.IntentParams memory p, bytes32 intentId) {
        p = CommodityAgent.IntentParams({
            maker: maker,
            srcChainSelector: LOCAL_SELECTOR,
            dstChainSelector: DST_SELECTOR,
            srcToken: address(commodityToken),
            dstReceiver: address(0x123),
            totalAmount: 100e18,
            nonce: 100,
            xauUsdRef: 2500e8,
            maxOracleDeviationBps: 50,
            deadline: uint40(block.timestamp + 600)
        });
        intentId = agent.createIntent(p, _signIntent(p));
        return (p, intentId);
    }

    function _createIntentSelectAndApprove() internal returns (CommodityAgent.IntentParams memory p, bytes32 intentId) {
        (p, intentId) = _createIntentAndAdvance();
        vm.prank(solver1);
        agent.submitBid(intentId, 1e18, 300000);
        vm.warp(block.timestamp + 61);
        agent.selectBid(intentId);
        vm.prank(maker);
        commodityToken.approve(address(agent), 100e18);
        return (p, intentId);
    }
}
