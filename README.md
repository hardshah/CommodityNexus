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

## TODOs / placeholders

- **XAU/USD oracle**: Base Sepolia / Arbitrum Sepolia: use a real Chainlink XAU/USD feed when available; agent uses `getLatestXauUsd()` or a placeholder (see README and code TODOs). [Chainlink Price Feeds](https://docs.chain.link/data-feeds).
- **SimpleAccount factory**: Default `SIMPLE_ACCOUNT_FACTORY=0x9406Cc6185a346906296840746125a0E44976454`; confirm for Base Sepolia / Arbitrum Sepolia from [ERC-4337 deployments](https://docs.erc4337.io/reference/smart-account-deployments) or Coinbase Paymaster docs.
