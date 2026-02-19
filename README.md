# CommodityNexus

Intent-based cross-chain commodity execution protocol with on-chain solver auctions, gasless ERC-4337 execution (Coinbase Paymaster), Chainlink CCIP programmable token transfers, Chainlink XAU/USD oracle risk checks, and Foundry tests.

## Architecture

- **Intent + RFQ/auction**: Makers post EIP-712–signed intents (source/destination chain, token, amount, XAU reference, deadline). Intents open a fixed 60s auction; solvers bid with execution cost and destination gas limit; the lowest-cost bid is selected.
- **Risk guardrails**: Before each CCIP send, the contract checks a Chainlink XAU/USD price feed for staleness and deviation from the maker’s reference price (configurable basis points and max age).
- **Cross-chain settlement**: Selected solver executes the fill; the contract pulls the commodity token from the maker, pays LINK fee, and calls CCIP Router to send tokens + payload to the destination chain. The destination CommodityAgent (CCIPReceiver) decodes the message and emits `DestinationExecution` (with a `mockSwap` placeholder for future DEX integration).
- **Gasless UX**: The TypeScript agent and solver send all on-chain writes as ERC-4337 UserOperations to the Coinbase Paymaster RPC (`eth_sendUserOperation`, `pm_getPaymasterData`, `eth_estimateUserOperationGas`, `eth_getUserOperationReceipt`), using a SimpleAccount (factory) and EntryPoint v0.6.

RWA/commodities narrative: XAU/USD oracle guardrails limit execution to acceptable price bands; cross-chain settlement and the RFQ-style auction support institutional commodity flows with programmable token transfers and solver competition.

## How to run

```bash
npm i
forge test
npm run agent    # intent creator (posts one intent via gasless UserOp)
npm run solver   # solver bot (bids, selects, executes via gasless UserOps)
```

Copy `.env.example` to `.env` and set:

- `PRIVATE_KEY`, `CDP_API_KEY_JSON_PATH`, `PAYMASTER_RPC`
- `BASE_SEPOLIA_RPC`, `ARBITRUM_SEPOLIA_RPC`
- `COMMODITY_AGENT_BASE`, `COMMODITY_AGENT_ARBITRUM` (deployed contract addresses)
- Optional: `INTENT_AMOUNT`, `COMMODITY_TOKEN_BASE` override

Deploy (one chain per run): set `CCIP_ROUTER`, `LINK_TOKEN`, optionally `CHAIN_SELECTOR` and `XAU_USD_ORACLE`; if `XAU_USD_ORACLE` is unset, the deploy script deploys a MockOracle. Then:

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url $RPC --broadcast --private-key $PK
```

## XAU/USD Oracle Setup

The contract requires a Chainlink XAU/USD price feed for risk checks. The agent script (`agent.ts`) automatically uses the oracle configured on the deployed contract via `getLatestXauUsd()`, or falls back to a placeholder ($2500/oz) if the oracle is not configured.

### Using a Real Chainlink XAU/USD Feed

1. **Find the feed address** for your network:
   - Visit [Chainlink Price Feeds Addresses](https://docs.chain.link/data-feeds/price-feeds/addresses)
   - Filter by network (Base Sepolia, Arbitrum Sepolia, etc.)
   - Search for "XAU/USD" or "Gold / USD"
   - Copy the Aggregator contract address

2. **Deploy with the oracle**:
   ```bash
   export XAU_USD_ORACLE=<chainlink-xau-usd-aggregator-address>
   forge script script/Deploy.s.sol:DeployScript \
     --rpc-url $BASE_SEPOLIA_RPC \
     --broadcast \
     --private-key $PRIVATE_KEY
   ```

3. **Verify oracle is set**:
   ```bash
   cast call $COMMODITY_AGENT_BASE "xauUsdOracle()(address)" --rpc-url $BASE_SEPOLIA_RPC
   ```

4. **Update oracle config** (if needed after deployment):
   ```bash
   cast send $COMMODITY_AGENT_BASE "setOracleConfig(address,uint16,uint32)" \
     <oracle-address> 50 3600 \
     --rpc-url $BASE_SEPOLIA_RPC \
     --private-key $OWNER_PRIVATE_KEY
   ```

### Fallback Behavior

- If `XAU_USD_ORACLE` env var is unset during deployment, the deploy script deploys a `MockOracleDeploy` with a fixed price ($2500/oz).
- The agent script (`agent.ts`) tries `getLatestXauUsd()` first; if it fails or returns invalid data, it uses a placeholder ($2500/oz) and logs a warning.
- For production, always deploy with a real Chainlink XAU/USD feed address.

## Proof of Reserve Setup

The contract supports Chainlink Proof of Reserve verification to ensure commodity tokens are backed by sufficient reserves. PoR checks are optional and can be configured per token.

### Configuring Proof of Reserve

1. **Find the PoR feed address** for your commodity token:
   - Visit [Chainlink Proof of Reserve Feeds](https://docs.chain.link/data-feeds/proof-of-reserve)
   - Find the feed for your token (e.g., WBTC, PAXG, etc.)
   - Copy the Aggregator contract address

2. **Set PoR configuration** after deployment:
   ```bash
   cast send $COMMODITY_AGENT_BASE "setProofOfReserveConfig(address,address,uint32)" \
     <token-address> <por-feed-address> 3600 \
     --rpc-url $BASE_SEPOLIA_RPC \
     --private-key $OWNER_PRIVATE_KEY
   ```

3. **Verify PoR status**:
   ```bash
   cast call $COMMODITY_AGENT_BASE "getProofOfReserve(address)(int256,uint256,uint256)" \
     <token-address> --rpc-url $BASE_SEPOLIA_RPC
   ```

### How PoR Works

- Before executing an intent fill, if a PoR feed is configured for the token, the contract:
  1. Fetches the latest proven reserves from the Chainlink PoR feed
  2. Checks that the feed is not stale (within configured max staleness window)
  3. Verifies that `reserves >= token.totalSupply()`
  4. Reverts with `ProofOfReserveInsufficient` or `ProofOfReserveStale` if checks fail

- If no PoR feed is configured for a token, the check is skipped (backward compatible)

- PoR feeds use the same `AggregatorV3Interface` as price feeds, making integration straightforward

## TODOs / placeholders

- **SimpleAccount factory**: Default `SIMPLE_ACCOUNT_FACTORY=0x9406Cc6185a346906296840746125a0E44976454`; confirm for Base Sepolia / Arbitrum Sepolia from [ERC-4337 deployments](https://docs.erc4337.io/reference/smart-account-deployments) or Coinbase Paymaster docs.
