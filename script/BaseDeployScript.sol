// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {ContractRegistry} from "./ContractRegistry.sol";

/**
 * @title BaseDeployScript
 * @dev Base deployment script providing simple contract saving functionality
 * Only requires one method: saveContract(contractName, contractAddress)
 */
abstract contract BaseDeployScript is Script {
    using ContractRegistry for *;

    /**
     * @dev Reads a contract address from contracts.json. Returns address(0) if missing.
     * @param contractName Contract name key in the registry
     */
    function getContractAddress(
        string memory contractName
    ) internal view returns (address) {
        string memory fileName = "contracts.json";
        string memory content;

        // Bail out if the file does not exist or is empty
        try vm.readFile(fileName) returns (string memory loaded) {
            if (bytes(loaded).length == 0) {
                return address(0);
            }
            content = loaded;
        } catch {
            return address(0);
        }

        string memory path = string.concat(".", contractName, ".address");
        try vm.parseJsonAddress(content, path) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    /**
     * @dev Save contract name and address to contracts.json
     * @param contractName Contract name
     * @param contractAddress Contract address
     */
    function saveContract(
        string memory contractName,
        address contractAddress
    ) internal {
        ContractRegistry.saveContract(vm, contractName, contractAddress);
    }

    struct Config {
        address weth;
        address permit2;
        bytes32 nativeCurrencyLabel;
        uint256 unsubscribeGasLimit;
    }

    function _getConfig() internal view returns (Config memory cfg) {
        if (block.chainid == 97) {
            cfg.weth = 0x04E0459121DB7D49AE932428762a44B616E967D6;
            cfg.permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
            cfg.nativeCurrencyLabel = bytes32("BNB");
            cfg.unsubscribeGasLimit = 150000;
        }
    }
}
