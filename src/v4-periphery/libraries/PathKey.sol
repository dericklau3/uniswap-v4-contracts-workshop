//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
}

using PathKeyLibrary for PathKey global;

/// @title PathKey 路径库
/// @notice 根据当前输入货币和下一跳描述构造规范化 PoolKey，并确定兑换方向。
library PathKeyLibrary {
    /// @notice 获取一个 PathKey 对应的池和兑换方向。
    /// @param params 当前路径段，包含下一种货币、费率、tickSpacing、hook 和 hookData。
    /// @param currencyIn 当前跳输入货币。
    /// @return poolKey 按货币地址排序后的池键。
    /// @return zeroForOne 输入为 currency0、输出为 currency1 时返回 true。
    function getPoolAndSwapDirection(PathKey calldata params, Currency currencyIn)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        Currency currencyOut = params.intermediateCurrency;
        (Currency currency0, Currency currency1) =
            currencyIn < currencyOut ? (currencyIn, currencyOut) : (currencyOut, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.fee, params.tickSpacing, params.hooks);
    }
}
