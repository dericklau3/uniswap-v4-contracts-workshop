// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ImmutableState} from "./ImmutableState.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolInitializer_v4} from "../interfaces/IPoolInitializer_v4.sol";

/// @title V4 池初始化器
/// @notice 按 `PoolKey` 和初始平方根价格初始化 Uniswap V4 池。
/// @dev 捕获“池已存在”等初始化失败，使集成方可在 multicall 中无条件尝试初始化并继续铸造流动性。
abstract contract PoolInitializer_v4 is ImmutableState, IPoolInitializer_v4 {
    /// @notice 初始化一个 V4 池。
    /// @param key 唯一标识池的 PoolKey。
    /// @param sqrtPriceX96 初始价格平方根的 Q96 表示。
    /// @return 初始化成功时的当前 tick；失败或池已初始化时返回 `type(int24).max`。
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        try poolManager.initialize(key, sqrtPriceX96) returns (int24 tick) {
            return tick;
        } catch {
            return type(int24).max;
        }
    }
}
