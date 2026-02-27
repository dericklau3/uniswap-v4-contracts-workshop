// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

/// @title HookFactory
/// @notice 专门用于部署Uniswap V4 hooks的工厂合约
/// @dev 使用CREATE2确保部署地址与HookMiner计算的地址一致
contract HookFactory {
    
    // 定义Hook部署事件
    event HookDeployed(address indexed hookAddress, bytes32 salt);

    /// @notice 部署hook合约
    /// @param salt 用于CREATE2部署的salt值
    /// @param creationCode hook合约的创建代码
    /// @param constructorArgs hook合约的构造函数参数
    /// @return hookAddress 部署的hook地址
    function deployHook(address predictedAddress, bytes32 salt, bytes memory creationCode, bytes memory constructorArgs) 
        public 
        returns (address hookAddress) 
    {
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);
        
        // 使用CREATE2部署合约
        assembly {
            hookAddress := create2(0, add(creationCodeWithArgs, 0x20), mload(creationCodeWithArgs), salt)
            if iszero(hookAddress) {
                revert(0, 0)
            }
        }
        require(hookAddress == predictedAddress, "hookAddress not match");
        // 触发Hook部署事件
        emit HookDeployed(hookAddress, salt);
        
        return hookAddress;
    }

    function find(uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        public
        view
        returns (address hookAddress, bytes32 salt)
    {
        return HookMiner.find(address(this), flags, creationCode, constructorArgs);
    }
}