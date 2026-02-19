// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract CommodityAgent is CCIPReceiver, Ownable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    enum IntentState {
        CREATED,
        AUCTION_OPEN,
        BID_SELECTED,
        EXECUTED
    }

    uint40 public constant AUCTION_WINDOW_SECONDS = 60;

    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "Intent(address maker,uint64 srcChainSelector,uint64 dstChainSelector,address srcToken,address dstReceiver,uint256 totalAmount,uint256 nonce,int256 xauUsdRef,uint16 maxOracleDeviationBps,uint40 deadline)"
    );

    IRouterClient public immutable ROUTER;
    IERC20 public immutable LINK_FEE_TOKEN;
    AggregatorV3Interface public xauUsdOracle;
    uint64 public immutable LOCAL_CHAIN_SELECTOR;
    uint16 public oracleDeviationBps;
    uint32 public oracleMaxStalenessSeconds;
    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    mapping(bytes32 => IntentRecord) internal intents;
    mapping(bytes32 => mapping(address => Bid)) internal bids;
    mapping(bytes32 => mapping(address => bool)) internal hasBid;

    struct IntentParams {
        address maker;
        uint64 srcChainSelector;
        uint64 dstChainSelector;
        address srcToken;
        address dstReceiver;
        uint256 totalAmount;
        uint256 nonce;
        int256 xauUsdRef;
        uint16 maxOracleDeviationBps;
        uint40 deadline;
    }

    struct IntentRecord {
        IntentParams params;
        IntentState state;
        uint40 createdAt;
        uint40 auctionOpenedAt;
        uint40 auctionClosesAt;
        uint256 filledAmount;
        address selectedSolver;
        uint96 selectedExecutionCost;
        uint32 selectedDstGasLimit;
    }

    struct Bid {
        address solver;
        uint96 executionCost;
        uint32 dstGasLimit;
        uint40 timestamp;
    }

    event IntentCreated(bytes32 indexed intentId, address indexed maker, uint256 totalAmount, uint256 nonce);
    event AuctionOpened(bytes32 indexed intentId, uint40 auctionClosesAt);
    event BidSubmitted(bytes32 indexed intentId, address indexed solver, uint96 executionCost, uint32 dstGasLimit);
    event BidSelected(bytes32 indexed intentId, address indexed solver, uint96 executionCost, uint32 dstGasLimit);
    event IntentExecuted(bytes32 indexed intentId, address indexed solver, uint256 fillAmount, bytes32 ccipMessageId);
    event DestinationExecution(bytes32 indexed intentId, bytes32 indexed ccipMessageId, uint256 fillAmount, address dstReceiver);
    event OracleConfigUpdated(address oracle, uint16 deviationBps, uint32 maxStalenessSeconds);

    error MissingOracle();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error InvalidIntentParams();
    error IntentExpired();
    error WrongState();
    error AuctionNotOpen();
    error AuctionStillOpen();
    error NoBids();
    error DuplicateBid();
    error NotSelectedSolver();
    error ZeroAmount();
    error OverFill();
    error OracleStale();
    error OracleDeviation();

    constructor(
        address router,
        address linkFeeToken,
        uint64 localChainSelector,
        address xauUsdOracle_,
        uint16 oracleDeviationBps_,
        uint32 oracleMaxStalenessSeconds_
    ) CCIPReceiver(router) Ownable(msg.sender) EIP712("CommodityNexus", "1") {
        ROUTER = IRouterClient(router);
        LINK_FEE_TOKEN = IERC20(linkFeeToken);
        LOCAL_CHAIN_SELECTOR = localChainSelector;
        xauUsdOracle = AggregatorV3Interface(xauUsdOracle_);
        oracleDeviationBps = oracleDeviationBps_;
        oracleMaxStalenessSeconds = oracleMaxStalenessSeconds_;
        emit OracleConfigUpdated(xauUsdOracle_, oracleDeviationBps_, oracleMaxStalenessSeconds_);
    }

    function createIntent(IntentParams calldata p, bytes calldata makerSig) external returns (bytes32 intentId) {
        if (p.maker == address(0)) revert InvalidIntentParams();
        if (p.srcChainSelector != LOCAL_CHAIN_SELECTOR) revert InvalidIntentParams();
        if (p.totalAmount == 0) revert InvalidIntentParams();
        if (p.dstReceiver == address(0)) revert InvalidIntentParams();
        if (p.deadline <= block.timestamp) revert IntentExpired();

        if (nonceUsed[p.maker][p.nonce]) revert NonceAlreadyUsed();

        bytes32 structHash = keccak256(
            abi.encode(
                INTENT_TYPEHASH,
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
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, makerSig);
        if (signer != p.maker) revert InvalidSignature();

        nonceUsed[p.maker][p.nonce] = true;

        intentId = keccak256(abi.encode(digest));
        IntentRecord storage rec = intents[intentId];
        rec.params = p;
        rec.state = IntentState.AUCTION_OPEN;
        rec.createdAt = uint40(block.timestamp);
        rec.auctionOpenedAt = uint40(block.timestamp);
        rec.auctionClosesAt = uint40(block.timestamp) + AUCTION_WINDOW_SECONDS;

        emit IntentCreated(intentId, p.maker, p.totalAmount, p.nonce);
        emit AuctionOpened(intentId, rec.auctionClosesAt);
    }

    function submitBid(bytes32 intentId, uint96 executionCost, uint32 dstGasLimit) external {
        IntentRecord storage rec = intents[intentId];
        if (rec.state != IntentState.AUCTION_OPEN) revert WrongState();
        if (block.timestamp > rec.auctionClosesAt) revert AuctionNotOpen();
        if (block.timestamp > rec.params.deadline) revert IntentExpired();
        if (hasBid[intentId][msg.sender]) revert DuplicateBid();

        bids[intentId][msg.sender] = Bid({
            solver: msg.sender,
            executionCost: executionCost,
            dstGasLimit: dstGasLimit,
            timestamp: uint40(block.timestamp)
        });
        hasBid[intentId][msg.sender] = true;

        if (rec.selectedSolver == address(0) || executionCost < rec.selectedExecutionCost) {
            rec.selectedSolver = msg.sender;
            rec.selectedExecutionCost = executionCost;
            rec.selectedDstGasLimit = dstGasLimit;
        }

        emit BidSubmitted(intentId, msg.sender, executionCost, dstGasLimit);
    }

    function selectBid(bytes32 intentId) external {
        IntentRecord storage rec = intents[intentId];
        if (rec.state != IntentState.AUCTION_OPEN) revert WrongState();
        if (block.timestamp <= rec.auctionClosesAt) revert AuctionStillOpen();
        if (rec.selectedSolver == address(0)) revert NoBids();

        rec.state = IntentState.BID_SELECTED;
        emit BidSelected(intentId, rec.selectedSolver, rec.selectedExecutionCost, rec.selectedDstGasLimit);
    }

    function executeIntent(bytes32 intentId) external nonReentrant returns (bytes32 ccipMessageId) {
        IntentRecord storage rec = intents[intentId];
        if (rec.state != IntentState.BID_SELECTED) revert WrongState();
        if (msg.sender != rec.selectedSolver) revert NotSelectedSolver();

        uint256 rem = remaining(intentId);
        ccipMessageId = _executeFill(intentId, rem);
        rec.filledAmount = rec.params.totalAmount;
        rec.state = IntentState.EXECUTED;
    }

    function executePartial(bytes32 intentId, uint256 amount) external nonReentrant returns (bytes32 ccipMessageId) {
        IntentRecord storage rec = intents[intentId];
        if (rec.state != IntentState.BID_SELECTED) revert WrongState();
        if (msg.sender != rec.selectedSolver) revert NotSelectedSolver();
        if (amount == 0) revert ZeroAmount();
        uint256 rem = remaining(intentId);
        if (amount > rem) revert OverFill();

        ccipMessageId = _executeFill(intentId, amount);
        rec.filledAmount += amount;
        if (rec.filledAmount == rec.params.totalAmount) {
            rec.state = IntentState.EXECUTED;
        }
    }

    function setOracleConfig(address oracle, uint16 deviationBps, uint32 maxStalenessSeconds) external onlyOwner {
        xauUsdOracle = AggregatorV3Interface(oracle);
        oracleDeviationBps = deviationBps;
        oracleMaxStalenessSeconds = maxStalenessSeconds;
        emit OracleConfigUpdated(oracle, deviationBps, maxStalenessSeconds);
    }

    function getIntent(bytes32 intentId) external view returns (IntentRecord memory) {
        return intents[intentId];
    }

    function remaining(bytes32 intentId) public view returns (uint256) {
        IntentRecord storage rec = intents[intentId];
        unchecked {
            return rec.params.totalAmount > rec.filledAmount ? rec.params.totalAmount - rec.filledAmount : 0;
        }
    }

    function getLatestXauUsd() external view returns (int256 price, uint256 updatedAt) {
        if (address(xauUsdOracle) == address(0)) revert MissingOracle();
        (, int256 p,, uint256 u,) = xauUsdOracle.latestRoundData();
        return (p, u);
    }

    function quoteCcipFee(bytes32 intentId, uint256 fillAmount) external view returns (uint256 fee) {
        IntentRecord storage rec = intents[intentId];
        uint32 gasLimit = rec.selectedDstGasLimit != 0 ? rec.selectedDstGasLimit : 300000;
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(rec.params.dstReceiver),
            data: abi.encode(intentId, fillAmount, rec.params.dstReceiver),
            tokenAmounts: _singleTokenAmount(rec.params.srcToken, fillAmount),
            feeToken: address(LINK_FEE_TOKEN),
            extraArgs: abi.encodeWithSelector(Client.EVM_EXTRA_ARGS_V1_TAG, Client.EVMExtraArgsV1({gasLimit: gasLimit}))
        });
        return ROUTER.getFee(rec.params.dstChainSelector, message);
    }

    function _singleTokenAmount(address token, uint256 amount) internal pure returns (Client.EVMTokenAmount[] memory) {
        Client.EVMTokenAmount[] memory arr = new Client.EVMTokenAmount[](1);
        arr[0] = Client.EVMTokenAmount({token: token, amount: amount});
        return arr;
    }

    function _executeFill(bytes32 intentId, uint256 fillAmount) internal returns (bytes32 ccipMessageId) {
        IntentRecord storage rec = intents[intentId];
        IntentParams memory p = rec.params;

        if (address(xauUsdOracle) == address(0)) revert MissingOracle();
        (, int256 price,, uint256 updatedAt,) = xauUsdOracle.latestRoundData();
        if (updatedAt == 0) revert OracleStale();
        if (block.timestamp - updatedAt > oracleMaxStalenessSeconds) revert OracleStale();
        if (price <= 0) revert OracleDeviation();
        uint16 deviationBps = p.maxOracleDeviationBps != 0 ? p.maxOracleDeviationBps : oracleDeviationBps;
        uint256 refAbs = p.xauUsdRef < 0 ? uint256(-p.xauUsdRef) : uint256(int256(p.xauUsdRef));
        uint256 diffAbs;
        if ((price >= 0 && p.xauUsdRef >= 0) || (price < 0 && p.xauUsdRef < 0)) {
            diffAbs = price >= p.xauUsdRef ? uint256(int256(price - p.xauUsdRef)) : uint256(int256(p.xauUsdRef - price));
        } else {
            uint256 priceAbs = price < 0 ? uint256(-price) : uint256(int256(price));
            diffAbs = priceAbs + refAbs;
        }
        if (diffAbs * 10_000 > refAbs * deviationBps) revert OracleDeviation();

        IERC20(p.srcToken).safeTransferFrom(p.maker, address(this), fillAmount);

        uint256 gasLimit = rec.selectedDstGasLimit != 0 ? rec.selectedDstGasLimit : 300000;
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(p.dstReceiver),
            data: abi.encode(intentId, fillAmount, p.dstReceiver),
            tokenAmounts: _singleTokenAmount(p.srcToken, fillAmount),
            feeToken: address(LINK_FEE_TOKEN),
            extraArgs: abi.encodeWithSelector(Client.EVM_EXTRA_ARGS_V1_TAG, Client.EVMExtraArgsV1({gasLimit: gasLimit}))
        });
        uint256 fee = ROUTER.getFee(p.dstChainSelector, message);
        if (LINK_FEE_TOKEN.balanceOf(address(this)) < fee) revert InvalidIntentParams();
        IERC20(p.srcToken).safeIncreaseAllowance(address(ROUTER), fillAmount);
        LINK_FEE_TOKEN.safeIncreaseAllowance(address(ROUTER), fee);
        ccipMessageId = ROUTER.ccipSend(p.dstChainSelector, message);

        emit IntentExecuted(intentId, msg.sender, fillAmount, ccipMessageId);
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        (bytes32 intentId, uint256 fillAmount, address dstReceiver) = abi.decode(message.data, (bytes32, uint256, address));
        mockSwap(intentId, fillAmount);
        emit DestinationExecution(intentId, message.messageId, fillAmount, dstReceiver);
    }

    /// @dev Placeholder for DEX integration; no external calls.
    function mockSwap(bytes32 intentId, uint256 fillAmount) internal {
        intentId;
        fillAmount;
        // TODO: integrate with DEX for commodity swap on destination.
    }
}
