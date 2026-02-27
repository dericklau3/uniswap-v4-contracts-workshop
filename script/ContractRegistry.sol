// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title ContractRegistry
 * @dev Simple contract registration library that only records contract names and addresses to contracts.json
 */
library ContractRegistry {
    struct LegacyEntry {
        string name;
        address addr;
    }
    
    /**
     * @dev Save contract information to contracts.json
     * @param vm Foundry VM instance
     * @param contractName Contract name
     * @param contractAddress Contract address
     */
    function saveContract(
        Vm vm,
        string memory contractName,
        address contractAddress
    ) internal {
        string memory fileName = "contracts.json";
        string memory existingContent = "{}";

        // Read existing file if possible
        try vm.readFile(fileName) returns (string memory content) {
            if (bytes(content).length != 0) {
                existingContent = ensureObjectFormat(vm, content);
            }
        } catch {
            existingContent = "{}";
        }

        // Collect existing contract entries
        string[] memory existingKeys;
        try vm.parseJsonKeys(existingContent, ".") returns (string[] memory keys) {
            existingKeys = keys;
        } catch {
            existingKeys = new string[](0);
        }

        bool exists = false;

        for (uint256 i = 0; i < existingKeys.length; i++) {
            if (keccak256(bytes(existingKeys[i])) == keccak256(bytes(contractName))) {
                exists = true;
                break;
            }
        }

        uint256 newLength = exists ? existingKeys.length : existingKeys.length + 1;
        string[] memory names = new string[](newLength);
        address[] memory addresses = new address[](newLength);
        uint256 index = 0;

        for (uint256 i = 0; i < existingKeys.length; i++) {
            string memory key = existingKeys[i];
            address storedAddress = address(0);

            string memory path = string.concat(".", key, ".address");
            try vm.parseJsonAddress(existingContent, path) returns (address parsed) {
                storedAddress = parsed;
            } catch {
                storedAddress = address(0);
            }

            if (keccak256(bytes(key)) == keccak256(bytes(contractName))) {
                storedAddress = contractAddress;
            }

            names[index] = key;
            addresses[index] = storedAddress;
            index++;
        }

        if (!exists) {
            names[index] = contractName;
            addresses[index] = contractAddress;
        }

        string memory updatedContent = buildJson(vm, names, addresses);

        // Write to file
        vm.writeFile(fileName, updatedContent);
        
        // Console output (only in non-test environment)
        console.log("Contract saved:", contractName, "at", contractAddress);
    }

    function ensureObjectFormat(Vm vm, string memory content) private pure returns (string memory) {
        bytes memory raw = bytes(content);

        uint256 length = raw.length;
        if (length == 0) {
            return "{}";
        }

        uint256 start = 0;
        while (start < length && isWhitespace(raw[start])) {
            start++;
        }

        if (start >= length) {
            return "{}";
        }

        bytes1 first = raw[start];

        if (first == "[") {
            try vm.parseJsonType(content, "(string name, address addr)[]") returns (bytes memory encoded) {
                LegacyEntry[] memory entries = abi.decode(encoded, (LegacyEntry[]));
                string[] memory names = new string[](entries.length);
                address[] memory addresses = new address[](entries.length);

                for (uint256 i = 0; i < entries.length; i++) {
                    names[i] = entries[i].name;
                    addresses[i] = entries[i].addr;
                }

                return buildJson(vm, names, addresses);
            } catch {
                return "{}";
            }
        } else if (first == "{") {
            return content;
        }

        return "{}";
    }

    function buildJson(
        Vm vm,
        string[] memory names,
        address[] memory addresses
    ) private pure returns (string memory) {
        require(names.length == addresses.length, "ContractRegistry: invalid lengths");

        if (names.length == 0) {
            return "{}\n";
        }

        string memory json = "{\n";
        for (uint256 i = 0; i < names.length; i++) {
            json = string.concat(
                json,
                '  "',
                names[i],
                '": {\n    "address": "',
                vm.toString(addresses[i]),
                '"\n  }'
            );

            if (i + 1 < names.length) {
                json = string.concat(json, ",\n");
            } else {
                json = string.concat(json, "\n");
            }
        }

        return string.concat(json, "}\n");
    }

    function isWhitespace(bytes1 char) private pure returns (bool) {
        return char == 0x20 || char == 0x0a || char == 0x0d || char == 0x09;
    }
}
