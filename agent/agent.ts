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
  "COMMODITY_TOKEN_BASE",
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

const COMMODITY_AGENT_ABI = [
  "function createIntent(tuple(address maker, uint64 srcChainSelector, uint64 dstChainSelector, address srcToken, address dstReceiver, uint256 totalAmount, uint256 nonce, int256 xauUsdRef, uint16 maxOracleDeviationBps, uint40 deadline) p, bytes makerSig) external returns (bytes32 intentId)",
  "function getLatestXauUsd() view returns (int256 price, uint256 updatedAt)",
];

async function main() {
  for (const k of ENV_VARS) requireEnv(k);
  const cdpPath = requireEnv("CDP_API_KEY_JSON_PATH");
  Coinbase.configureFromJson({ filePath: cdpPath });

  const provider = new ethers.JsonRpcProvider(requireEnv("BASE_SEPOLIA_RPC"));
  const wallet = new ethers.Wallet(requireEnv("PRIVATE_KEY"), provider);
  const paymasterRpc = requireEnv("PAYMASTER_RPC");
  const agentAddress = requireEnv("COMMODITY_AGENT_BASE");
  const baseSelector = BigInt(requireEnv("BASE_SEPOLIA_SELECTOR"));
  const arbSelector = BigInt(requireEnv("ARBITRUM_SEPOLIA_SELECTOR"));
  const srcToken = requireEnv("COMMODITY_TOKEN_BASE");
  const dstReceiver = requireEnv("COMMODITY_AGENT_ARBITRUM");
  const totalAmount = process.env.INTENT_AMOUNT ? BigInt(process.env.INTENT_AMOUNT) : BigInt(1e18);
  const factoryAddress = requireEnv("SIMPLE_ACCOUNT_FACTORY");
  const entryPointAddress = requireEnv("ENTRYPOINT_V06");
  const salt = 0n;

  const agent = new ethers.Contract(agentAddress, COMMODITY_AGENT_ABI, provider);
  const chainId = (await provider.getNetwork()).chainId;
  let xauUsdRef = 2500e8; // Default placeholder: $2500/oz (8 decimals)
  try {
    const [price, updatedAt] = await agent.getLatestXauUsd();
    if (price != null && price !== 0n && updatedAt != null && updatedAt !== 0n) {
      xauUsdRef = Number(price);
      console.log(`Using XAU/USD from oracle: ${xauUsdRef / 1e8} (updated at ${new Date(Number(updatedAt) * 1000).toISOString()})`);
    } else {
      console.warn(`Oracle returned invalid data (price=${price}, updatedAt=${updatedAt}), using placeholder: ${xauUsdRef / 1e8}`);
    }
  } catch (e: unknown) {
    const errMsg = e instanceof Error ? e.message : String(e);
    if (errMsg.includes("MissingOracle") || errMsg.includes("execution reverted")) {
      console.warn(`XAU/USD oracle not configured on contract (${agentAddress}), using placeholder: ${xauUsdRef / 1e8}`);
      console.warn(`To use a real Chainlink XAU/USD feed, deploy CommodityAgent with XAU_USD_ORACLE env var set.`);
      console.warn(`See: https://docs.chain.link/data-feeds/price-feeds/addresses`);
    } else {
      console.warn(`Failed to fetch XAU/USD from oracle: ${errMsg}, using placeholder: ${xauUsdRef / 1e8}`);
    }
  }

  const nonce = process.hrtime.bigint();
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
  const intentParams = {
    maker: wallet.address,
    srcChainSelector: baseSelector,
    dstChainSelector: arbSelector,
    srcToken,
    dstReceiver,
    totalAmount,
    nonce,
    xauUsdRef: BigInt(xauUsdRef),
    maxOracleDeviationBps: 50,
    deadline,
  };

  const domain = {
    name: "CommodityNexus",
    version: "1",
    chainId: Number(chainId),
    verifyingContract: agentAddress,
  };
  const types = {
    Intent: [
      { name: "maker", type: "address" },
      { name: "srcChainSelector", type: "uint64" },
      { name: "dstChainSelector", type: "uint64" },
      { name: "srcToken", type: "address" },
      { name: "dstReceiver", type: "address" },
      { name: "totalAmount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "xauUsdRef", type: "int256" },
      { name: "maxOracleDeviationBps", type: "uint16" },
      { name: "deadline", type: "uint40" },
    ],
  };
  const makerSig = await wallet.signTypedData(domain, types, intentParams);

  const factory = new ethers.Contract(factoryAddress, FACTORY_ABI, provider);
  const sender = await factory.getAddress(wallet.address, salt);
  const entryPoint = new ethers.Contract(entryPointAddress, ENTRYPOINT_ABI, provider);
  const iface = new ethers.Interface(COMMODITY_AGENT_ABI);
  const callData = iface.encodeFunctionData("createIntent", [intentParams, makerSig]);

  const initCode = await getInitCode(provider, factoryAddress, wallet.address, salt, sender);
  const nonceKey = 0n;
  const accountNonce = await entryPoint.getNonce(sender, nonceKey);

  const feeData = await provider.getFeeData();
  const maxFeePerGas = feeData.maxFeePerGas ?? BigInt(2e9);
  const maxPriorityFeePerGas = feeData.maxPriorityFeePerGas ?? BigInt(1e9);

  const dummySig = ethers.hexlify(new Uint8Array(65));
  const userOp = {
    sender,
    nonce: "0x" + accountNonce.toString(16),
    initCode,
    callData,
    callGasLimit: "0x" + (500_000n).toString(16),
    verificationGasLimit: "0x" + (200_000n).toString(16),
    preVerificationGas: "0x" + (100_000n).toString(16),
    maxFeePerGas: "0x" + maxFeePerGas.toString(16),
    maxPriorityFeePerGas: "0x" + maxPriorityFeePerGas.toString(16),
    paymasterAndData: "0x",
    signature: dummySig,
  };

  const paymasterProvider = new ethers.JsonRpcProvider(paymasterRpc);
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
  if (!paymasterAndData) throw new Error("paymasterAndData missing from pm_getPaymasterData response: " + JSON.stringify(pmData));
  userOp.paymasterAndData = paymasterAndData;

  const userOpForHash = { ...userOp, signature: "0x" };
  const userOpHash = await entryPoint.getUserOpHash(packUserOp(userOpForHash));
  userOp.signature = await wallet.signMessage(ethers.getBytes(userOpHash));

  const sendResult = await paymasterProvider.send("eth_sendUserOperation", [packUserOp(userOp), entryPointAddress]).catch((e: unknown) => {
    console.error("eth_sendUserOperation error:", JSON.stringify(e, null, 2));
    throw e;
  });
  const opHash = typeof sendResult?.result === "string" ? sendResult.result : sendResult?.result?.hash ?? sendResult;
  console.log("UserOp hash:", opHash);

  const receipt = await pollUserOpReceipt(paymasterProvider, entryPointAddress, opHash);
  console.log("status:", receipt?.success ? "success" : "failed");
  if (receipt?.transactionHash) console.log("tx hash:", receipt.transactionHash);
  if (receipt && !receipt.success) console.error("receipt:", JSON.stringify(receipt, null, 2));
}

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

async function pollUserOpReceipt(provider: ethers.JsonRpcProvider, entryPoint: string, opHash: string, timeoutMs = 60_000): Promise<{ success: boolean; transactionHash?: string } | null> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const res = await provider.send("eth_getUserOperationReceipt", [opHash]).catch(() => null);
    const receipt = res?.result ?? res;
    if (receipt?.success !== undefined) return { success: !!receipt.success, transactionHash: receipt.receipt?.transactionHash };
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error("Timeout waiting for UserOperation receipt: " + opHash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
