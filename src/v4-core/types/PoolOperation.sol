// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";

/// @notice `ModifyLiquidity` 池操作的参数结构体。
struct ModifyLiquidityParams {
    // 仓位的下边界与上边界 tick。
    int24 tickLower;
    int24 tickUpper;
    // 流动性修改量：正数增加，负数移除。
    int256 liquidityDelta;
    // 当同一所有者需要在相同价格区间建立多个独立仓位时，用 salt 区分仓位。
    bytes32 salt;
}

/// @notice `Swap` 池操作的参数结构体。
struct SwapParams {
    /// 兑换方向：true 表示 token0 换 token1，false 表示 token1 换 token0。
    bool zeroForOne;
    /// 指定数量：负数表示期望输入量（exactIn），正数表示期望输出量（exactOut）。
    int256 amountSpecified;
    /// 兑换执行到该平方根价格时停止，用于限制成交价格边界。
    uint160 sqrtPriceLimitX96;
}
