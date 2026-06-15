// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "./Currency.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {PoolIdLibrary} from "./PoolId.sol";

using PoolIdLibrary for PoolKey global;

/// @notice 唯一标识一个 Uniswap V4 池所需的完整配置。
struct PoolKey {
    /// @notice 按地址数值排序后较小的池货币。
    Currency currency0;
    /// @notice 按地址数值排序后较大的池货币。
    Currency currency1;
    /// @notice 池的 LP 费率，上限为 1_000_000；最高位为 1 时表示动态费率池，此值必须严格等于 0x800000。
    uint24 fee;
    /// @notice 仓位使用的 tick 必须是 tickSpacing 的整数倍。
    int24 tickSpacing;
    /// @notice 该池绑定的 hooks 合约。
    IHooks hooks;
}
