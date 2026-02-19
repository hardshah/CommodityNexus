import "dotenv/config";
import { ethers } from "ethers";
import { Coinbase } from "@coinbase/coinbase-sdk";

const ENV_VARS = [
  "PRIVATE_KEY",
  "CDP_API_KEY_JSON_PATH",
  "PAYMASTER_RPC",
  "BASE_SEPOLIA_RPC",
  "BASE_SEPOLIA_SELECTOR",
  "ARBITRUM_SEPOLIA_SELECTOR",
  "CCIP_ROUTER_BASE",
  "CCIP_ROUTER_ARBITRUM",
  "LINK_TOKEN_BASE",
  "LINK_TOKEN_ARBITRUM",
  "COMMODITY_AGENT_BASE",
  "COMMODITY_AGENT_ARBITRUM",
  "SIMPLE_ACCOUNT_FACTORY",
  "ENTRYPOINT_V06",
] as const;

function requireEnv(name: string): string {
  const v = process.env[name];
  if (v == null || v === "") throw new Error(`Missing required env var: ${name}`);
  return v;
}

const ENTRYPOINT_ABI = [
  "function getNonce(address sender, uint192 key) view returns (uint256)",
  "function getUserOpHash(tuple(address sender, uint256 nonce, bytes initCode, bytes callData, uint256 callGasLimit, uint256 verificationGasLimit, uint256 preVerificationGas, uint256 maxFeePerGas, uint256 maxPriorityFeePerGas, bytes paymasterAndData, bytes signature) userOp) view returns (bytes32)",
];

const FACTORY_ABI = [
  "function getAddress(address owner, uint256 salt) view returns (address)",
  "function createAccount(address owner, uint256 salt) returns (address)",
];

const AGENT_ABI = [
  "function submitBid(bytes32 intentId, uint96 executionCost, uint32 dstGasLimit) external",
  "function selectBid(bytes32 intentId) external",
  "function executeIntent(bytes32 intentId) external returns (bytes32)",
  "function executePartial(bytes32 intentId, uint256 amount) external returns (bytes32)",
  "function remaining(bytes32 intentId) view returns (uint256)",
  "function quoteCcipFee(bytes32 intentId, uint256 fillAmount) view returns (uint256)",
  "function getIntent(bytes32 intentId) view returns (tuple(tuple(address maker, uint64 srcChainSelector, uint64 dstChainSelector, address srcToken, address dstReceiver, uint256 totalAmount, uint256 nonce, int256 xauUsdRef, uint16 maxOracleDeviationBps, uint40 deadline) params, uint8 state, uint40 createdAt, uint40 auctionOpenedAt, uint40 auctionClosesAt, uint256 filledAmount, address selectedSolver, uint96 selectedExecutionCost, uint32 selectedDstGasLimit))",
  "event IntentCreated(bytes32 indexed intentId, address indexed maker, uint256 totalAmount, uint256 nonce)",
  "event AuctionOpened(bytes32 indexed intentId, uint40 auctionClosesAt)",
  "event BidSelected(bytes32 indexed intentId, address indexed solver, uint96 executionCost, uint32 dstGasLimit)",
  "event IntentExecuted(bytes32 indexed intentId, address indexed solver, uint256 fillAmount, bytes32 ccipMessageId)",
];

const AUCTION_OPEN = 1;
const BID_SELECTED = 2;
const EXECUTED = 3;
const POLL_INTERVAL_MS = 3000;
const DEFAULT_DST_GAS = 300000;
const SOLVER_PREMIUM = BigInt(1e16);

function packUserOp(op: Record<string, unknown>): Record<string, string> {
  return {
    sender: op.sender as string,
    nonce: op.nonce as string,
    initCode: op.initCode as string,
    callData: op.callData as string,
    callGasLimit: op.callGasLimit as string,
    verificationGasLimit: op.verificationGasLimit as string,
    preVerificationGas: op.preVerificationGas as string,
    maxFeePerGas: op.maxFeePerGas as string,
    maxPriorityFeePerGas: op.maxPriorityFeePerGas as string,
    paymasterAndData: op.paymasterAndData as string,
    signature: op.signature as string,
  };
}

async function getInitCode(provider: ethers.Provider, factoryAddress: string, owner: string, salt: bigint, sender: string): Promise<string> {
  const code = await provider.getCode(sender);
  if (code && code !== "0x") return "0x";
  const iface = new ethers.Interface(FACTORY_ABI);
  const data = iface.encodeFunctionData("createAccount", [owner, salt]);
  return ethers.concat([factoryAddress as `0x${string}`, data as `0x${string}`]);
}

async function sendUserOp(
  paymasterProvider: ethers.JsonRpcProvider,
  entryPointAddress: string,
  wallet: ethers.Wallet,
  entryPoint: ethers.Contract,
  userOp: Record<string, unknown>,
  initCode: string
): Promise<{ opHash: string; receipt: { success: boolean; transactionHash?: string } }> {
  userOp.initCode = initCode;
  const dummySig = ethers.hexlify(new Uint8Array(65));
  userOp.signature = dummySig;
  const feeData = await (wallet.provider as ethers.JsonRpcProvider).getFeeData();
  userOp.maxFeePerGas = "0x" + (feeData.maxFeePerGas ?? BigInt(2e9)).toString(16);
  userOp.maxPriorityFeePerGas = "0x" + (feeData.maxPriorityFeePerGas ?? BigInt(1e9)).toString(16);

  const est = await paymasterProvider.send("eth_estimateUserOperationGas", [packUserOp(userOp), entryPointAddress]).catch((e: unknown) => {
    console.error("eth_estimateUserOperationGas error:", JSON.stringify(e, null, 2));
    throw e;
  });
  if (est?.callGasLimit) userOp.callGasLimit = est.callGasLimit;
  if (est?.verificationGasLimit) userOp.verificationGasLimit = est.verificationGasLimit;
  if (est?.preVerificationGas) userOp.preVerificationGas = est.preVerificationGas;

  const pmData = await paymasterProvider.send("pm_getPaymasterData", [packUserOp(userOp), entryPointAddress]).catch((e: unknown) => {
    console.error("pm_getPaymasterData error:", JSON.stringify(e, null, 2));
    throw e;
  });
  const paymasterAndData = pmData?.result?.paymasterAndData ?? pmData?.paymasterAndData;
  if (!paymasterAndData) throw new Error("paymasterAndData missing: " + JSON.stringify(pmData));
  userOp.paymasterAndData = paymasterAndData;

  const userOpForHash = { ...userOp, signature: "0x" };
  const userOpHash = await entryPoint.getUserOpHash(packUserOp(userOpForHash));
  userOp.signature = await wallet.signMessage(ethers.getBytes(userOpHash));

  const sendResult = await paymasterProvider.send("eth_sendUserOperation", [packUserOp(userOp), entryPointAddress]).catch((e: unknown) => {
    console.error("eth_sendUserOperation error:", JSON.stringify(e, null, 2));
    throw e;
  });
  const opHash = typeof sendResult?.result === "string" ? sendResult.result : sendResult?.result?.hash ?? sendResult;
  if (!opHash || typeof opHash !== "string") throw new Error("No UserOp hash in response: " + JSON.stringify(sendResult));

  const timeoutMs = 60_000;
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const res = await paymasterProvider.send("eth_getUserOperationReceipt", [opHash]).catch(() => null);
    const receipt = res?.result ?? res;
    if (receipt?.success !== undefined) {
      return { opHash, receipt: { success: !!receipt.success, transactionHash: receipt.receipt?.transactionHash } };
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error("Timeout waiting for UserOperation receipt: " + opHash);
}

async function main() {
  for (const k of ENV_VARS) requireEnv(k);
  const cdpPath = requireEnv("CDP_API_KEY_JSON_PATH");
  Coinbase.configureFromJson({ filePath: cdpPath });

  const provider = new ethers.JsonRpcProvider(requireEnv("BASE_SEPOLIA_RPC"));
  const wallet = new ethers.Wallet(requireEnv("PRIVATE_KEY"), provider);
  const paymasterRpc = requireEnv("PAYMASTER_RPC");
  const paymasterProvider = new ethers.JsonRpcProvider(paymasterRpc);
  const agentAddress = requireEnv("COMMODITY_AGENT_BASE");
  const factoryAddress = requireEnv("SIMPLE_ACCOUNT_FACTORY");
  const entryPointAddress = requireEnv("ENTRYPOINT_V06");
  const salt = 0n;

  const agent = new ethers.Contract(agentAddress, AGENT_ABI, provider);
  const factory = new ethers.Contract(factoryAddress, FACTORY_ABI, provider);
  const entryPoint = new ethers.Contract(entryPointAddress, ENTRYPOINT_ABI, provider);
  const sender = await factory.getAddress(wallet.address, salt);
  const initCode = await getInitCode(provider, factoryAddress, wallet.address, salt, sender);

  const activeAuctions = new Map<string, { intentId: string; auctionClosesAt: number }>();
  const bidSent = new Set<string>();
  const selectedIntents = new Map<string, { intentId: string; selectedSolver: string }>();

  async function scanEvents(fromBlock: number) {
    const toBlock = await provider.getBlockNumber();
    if (toBlock < fromBlock) return;
    const intentCreated = await agent.queryFilter(agent.filters.IntentCreated(), fromBlock, toBlock);
    const auctionOpened = await agent.queryFilter(agent.filters.AuctionOpened(), fromBlock, toBlock);
    const bidSelected = await agent.queryFilter(agent.filters.BidSelected(), fromBlock, toBlock);
    const intentExecuted = await agent.queryFilter(agent.filters.IntentExecuted(), fromBlock, toBlock);
    for (const e of intentCreated) {
      const intentId = (e as ethers.EventLog).args?.intentId ?? (e as { args: [string] }).args[0];
      activeAuctions.set(intentId, { intentId, auctionClosesAt: 0 });
    }
    for (const e of auctionOpened) {
      const intentId = (e as ethers.EventLog).args?.intentId ?? (e as { args: [string] }).args[0];
      const auctionClosesAt = Number((e as ethers.EventLog).args?.auctionClosesAt ?? 0);
      activeAuctions.set(intentId, { intentId, auctionClosesAt });
    }
    for (const e of bidSelected) {
      const intentId = (e as ethers.EventLog).args?.intentId ?? (e as { args: [string] }).args[0];
      const solver = (e as ethers.EventLog).args?.solver ?? (e as { args: unknown[] }).args[1];
      activeAuctions.delete(intentId);
      selectedIntents.set(intentId, { intentId, selectedSolver: solver });
    }
    for (const e of intentExecuted) {
      const intentId = (e as ethers.EventLog).args?.intentId ?? (e as { args: [string] }).args[0];
      selectedIntents.delete(intentId);
    }
    return toBlock;
  }

  let lastBlock = await provider.getBlockNumber();
  lastBlock = (await scanEvents(Math.max(0, lastBlock - 100))) ?? lastBlock;

  for (;;) {
    lastBlock = (await scanEvents(lastBlock + 1)) ?? lastBlock;

    const now = Math.floor(Date.now() / 1000);
    for (const [, info] of activeAuctions) {
      const rec = await agent.getIntent(info.intentId);
      if (Number(rec.state) !== AUCTION_OPEN) continue;
      if (now > info.auctionClosesAt && info.auctionClosesAt > 0) continue;
      if (bidSent.has(info.intentId)) continue;

      let executionCost: bigint;
      try {
        const rem = await agent.remaining(info.intentId);
        const fee = await agent.quoteCcipFee(info.intentId, rem);
        executionCost = BigInt(fee) + SOLVER_PREMIUM;
      } catch (e) {
        console.warn("quoteCcipFee failed for", info.intentId, e);
        continue;
      }

      const accountNonce = await entryPoint.getNonce(sender, 0n);
      const iface = new ethers.Interface(AGENT_ABI);
      const callData = iface.encodeFunctionData("submitBid", [info.intentId, executionCost, DEFAULT_DST_GAS]);
      const userOp = {
        sender,
        nonce: "0x" + accountNonce.toString(16),
        initCode: "0x",
        callData,
        callGasLimit: "0x" + (500_000n).toString(16),
        verificationGasLimit: "0x" + (200_000n).toString(16),
        preVerificationGas: "0x" + (100_000n).toString(16),
        maxFeePerGas: "0x0",
        maxPriorityFeePerGas: "0x0",
        paymasterAndData: "0x",
        signature: "0x",
      };
      try {
        const { opHash, receipt } = await sendUserOp(paymasterProvider, entryPointAddress, wallet, entryPoint, userOp, initCode);
        console.log("submitBid UserOp hash:", opHash, "status:", receipt.success, receipt.transactionHash ? "tx:" + receipt.transactionHash : "");
        bidSent.add(info.intentId);
      } catch (e) {
        console.error("submitBid failed:", e);
      }
    }

    for (const [, info] of Array.from(selectedIntents)) {
      const rec = await agent.getIntent(info.intentId);
      if (Number(rec.state) === BID_SELECTED && rec.selectedSolver?.toLowerCase() === wallet.address.toLowerCase()) {
        const rem = await agent.remaining(info.intentId);
        if (rem === 0n) continue;
        const half = rem / 2n;
        const accountNonce = await entryPoint.getNonce(sender, 0n);
        const iface = new ethers.Interface(AGENT_ABI);
        if (half > 0n) {
          const callDataPartial = iface.encodeFunctionData("executePartial", [info.intentId, half]);
          const userOpPartial = {
            sender,
            nonce: "0x" + accountNonce.toString(16),
            initCode: "0x",
            callData: callDataPartial,
            callGasLimit: "0x" + (500_000n).toString(16),
            verificationGasLimit: "0x" + (200_000n).toString(16),
            preVerificationGas: "0x" + (100_000n).toString(16),
            maxFeePerGas: "0x0",
            maxPriorityFeePerGas: "0x0",
            paymasterAndData: "0x",
            signature: "0x",
          };
          try {
            const { opHash, receipt } = await sendUserOp(paymasterProvider, entryPointAddress, wallet, entryPoint, userOpPartial, initCode);
            console.log("executePartial UserOp hash:", opHash, "status:", receipt.success);
          } catch (e) {
            console.error("executePartial failed:", e);
          }
        }
        const accountNonce2 = await entryPoint.getNonce(sender, 0n);
        const callDataFinal = iface.encodeFunctionData("executeIntent", [info.intentId]);
        const userOpFinal = {
          sender,
          nonce: "0x" + accountNonce2.toString(16),
          initCode: "0x",
          callData: callDataFinal,
          callGasLimit: "0x" + (500_000n).toString(16),
          verificationGasLimit: "0x" + (200_000n).toString(16),
          preVerificationGas: "0x" + (100_000n).toString(16),
          maxFeePerGas: "0x0",
          maxPriorityFeePerGas: "0x0",
          paymasterAndData: "0x",
          signature: "0x",
        };
        try {
          const { opHash, receipt } = await sendUserOp(paymasterProvider, entryPointAddress, wallet, entryPoint, userOpFinal, initCode);
          console.log("executeIntent UserOp hash:", opHash, "status:", receipt.success);
        } catch (e) {
          console.error("executeIntent failed:", e);
        }
        selectedIntents.delete(info.intentId);
      }
    }

    for (const [key, info] of Array.from(activeAuctions)) {
      const rec = await agent.getIntent(info.intentId);
      if (Number(rec.state) !== AUCTION_OPEN) continue;
      if (now <= info.auctionClosesAt || info.auctionClosesAt === 0) continue;
      const accountNonce = await entryPoint.getNonce(sender, 0n);
      const iface = new ethers.Interface(AGENT_ABI);
      const callData = iface.encodeFunctionData("selectBid", [info.intentId]);
      const userOp = {
        sender,
        nonce: "0x" + accountNonce.toString(16),
        initCode: "0x",
        callData,
        callGasLimit: "0x" + (500_000n).toString(16),
        verificationGasLimit: "0x" + (200_000n).toString(16),
        preVerificationGas: "0x" + (100_000n).toString(16),
        maxFeePerGas: "0x0",
        maxPriorityFeePerGas: "0x0",
        paymasterAndData: "0x",
        signature: "0x",
      };
      try {
        const { opHash, receipt } = await sendUserOp(paymasterProvider, entryPointAddress, wallet, entryPoint, userOp, initCode);
        console.log("selectBid UserOp hash:", opHash, "status:", receipt.success);
      } catch (e) {
        console.error("selectBid failed:", e);
      }
      activeAuctions.delete(key);
    }

    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
