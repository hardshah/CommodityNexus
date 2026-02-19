// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import {CommodityAgent} from "../src/CommodityAgent.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MockOracleDeploy is AggregatorV3Interface {
    int256 public price = 2500e8;
    uint256 public updatedAt = block.timestamp;
    uint80 public roundId = 1;

    function decimals() external pure override returns (uint8) { return 8; }
    function description() external pure override returns (string memory) { return "XAU/USD Mock"; }
    function version() external pure override returns (uint256) { return 1; }
    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, roundId);
    }
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, price, updatedAt, updatedAt, roundId);
    }
}

contract DeployScript is Script {
    function run() external {
        address router = vm.envAddress("CCIP_ROUTER");
        address linkToken = vm.envAddress("LINK_TOKEN");
        uint64 chainSelector = uint64(vm.envOr("CHAIN_SELECTOR", uint256(10344971235874465080)));
        address xauOracle = vm.envOr("XAU_USD_ORACLE", address(0));

        if (xauOracle == address(0)) {
            vm.broadcast();
            MockOracleDeploy mockOracle = new MockOracleDeploy();
            xauOracle = address(mockOracle);
        }

        vm.broadcast();
        CommodityAgent agent = new CommodityAgent(
            router,
            linkToken,
            chainSelector,
            xauOracle,
            50,
            3600
        );
        console.log("CommodityAgent deployed at:", address(agent));
    }
}
