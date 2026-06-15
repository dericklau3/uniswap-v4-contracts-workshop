// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BitMath} from "./BitMath.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @title tick 与平方根价格互相转换的数学库
/// @notice 每个 tick 的价格倍率为 1.0001，本库把 sqrt(1.0001^tick) 表示为 Q64.96 定点数，
///         并支持 2**-128 到 2**128 之间的价格。
library TickMath {
    using CustomRevert for bytes4;

    /// @notice 传给 #getSqrtPriceAtTick 的 tick 不在 MIN_TICK 与 MAX_TICK 之间时抛出。
    error InvalidTick(int24 tick);
    /// @notice 传给 #getTickAtSqrtPrice 的价格不对应 MIN_TICK 与 MAX_TICK 之间的价格时抛出。
    error InvalidSqrtPrice(uint160 sqrtPriceX96);

    /// @dev #getSqrtPriceAtTick 可接收的最小 tick，由以 1.0001 为底的 2**-128 对数计算得出。
    /// @dev 若 MIN_TICK 与 MAX_TICK 不再以 0 对称，getSqrtPriceAtTick 的 absTick 逻辑将不再适用。
    int24 internal constant MIN_TICK = -887272;
    /// @dev #getSqrtPriceAtTick 可接收的最大 tick，由以 1.0001 为底的 2**128 对数计算得出。
    /// @dev 若 MIN_TICK 与 MAX_TICK 不再以 0 对称，getSqrtPriceAtTick 的 absTick 逻辑将不再适用。
    int24 internal constant MAX_TICK = 887272;

    /// @dev int16 正数范围内允许的最小 tick spacing，即 [1, 32767] 的最小值。
    int24 internal constant MIN_TICK_SPACING = 1;
    /// @dev int16 范围内允许的最大 tick spacing，即 [1, 32767] 的最大值。
    int24 internal constant MAX_TICK_SPACING = type(int16).max;

    /// @dev #getSqrtPriceAtTick 可返回的最小值，等价于 getSqrtPriceAtTick(MIN_TICK)。
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    /// @dev #getSqrtPriceAtTick 可返回的最大值，等价于 getSqrtPriceAtTick(MAX_TICK)。
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    /// @dev 用于优化边界检查的阈值，等于 `MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1`。
    uint160 internal constant MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE =
        1461446703485210103287273052203988822378723970342 - 4295128739 - 1;

    /// @notice 根据 tickSpacing 计算不超过 MAX_TICK 的最大可用 tick。
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MAX_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice 根据 tickSpacing 计算不小于 MIN_TICK 的最小可用 tick。
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (MIN_TICK / tickSpacing) * tickSpacing;
        }
    }

    /// @notice 计算 sqrt(1.0001^tick) * 2^96。
    /// @dev 当 |tick| > MAX_TICK 时回滚。
    /// @param tick 代入上述公式的 tick。
    /// @return sqrtPriceX96 该 tick 下两种资产价格（currency1/currency0）平方根的 Q64.96 定点表示。
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                // tick >= 0 时 mask = 0，否则 mask = -1（全部 bit 为 1）。
                let mask := sar(255, tick)
                // tick >= 0 时，|tick| = tick = 0 ^ tick。
                // tick < 0 时，|tick| = ~~|tick| = ~(-|tick| - 1) = ~(tick - 1) = (-1) ^ (tick - 1)。
                // 两种情况都可统一为 |tick| = mask ^ (tick + mask)。
                absTick := xor(mask, add(mask, tick))
            }

            if (absTick > uint256(int256(MAX_TICK))) InvalidTick.selector.revertWith(tick);

            // 将 tick 分解为二进制 bit。对每个被置位的索引 i，累乘 1/sqrt(1.0001^(2^i)) 的 Q128.128 值。
            // 下列常量均舍入到最接近的整数。

            // 等价于：
            //     price = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            //     or price = int(2**128 / sqrt(1.0001)) if (absTick & 0x1) else 1 << 128
            uint256 price;
            assembly ("memory-safe") {
                price := xor(shl(128, 1), mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1)))
            }
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

            assembly ("memory-safe") {
                // tick > 0 时取倒数：price = type(uint256).max / price。
                if sgt(tick, 0) { price := div(not(0), price) }

                // 除以 1<<32 并向上取整，把 Q128.128 转为 Q128.96。
                // tick 输入边界保证结果始终放得进 160 bit，因此随后可安全向下转换。
                // 此处向上取整，使输出价格再传入 getTickAtSqrtPrice 时始终得到一致 tick。
                // `sub(shl(32, 1), 1)` 即 `type(uint32).max`。
                // `price` 最多占 192 bit，因此 `price + type(uint32).max` 不会溢出。
                sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
            }
        }
    }

    /// @notice 计算满足 getSqrtPriceAtTick(tick) <= sqrtPriceX96 的最大 tick。
    /// @dev sqrtPriceX96 < MIN_SQRT_PRICE 时回滚，因为 MIN_SQRT_PRICE 已是 getSqrtPriceAtTick 的最小可能返回值。
    /// @param sqrtPriceX96 要反推 tick 的 Q64.96 平方根价格。
    /// @return tick 满足其对应平方根价格不大于输入价格的最大 tick。
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        unchecked {
            // 等价于：if (sqrtPriceX96 < MIN_SQRT_PRICE || sqrtPriceX96 >= MAX_SQRT_PRICE) revert InvalidSqrtPrice();
            // 第二个不等式必须使用 >=，因为池价格永远不能真正到达最大 tick 对应价格。
            // sqrtPriceX96 < MIN_SQRT_PRICE 时，`sub` 下溢且 `gt` 为 true。
            // sqrtPriceX96 >= MAX_SQRT_PRICE 时，差值会大于 MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1。
            if ((sqrtPriceX96 - MIN_SQRT_PRICE) > MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE) {
                InvalidSqrtPrice.selector.revertWith(sqrtPriceX96);
            }

            uint256 price = uint256(sqrtPriceX96) << 32;

            uint256 r = price;
            uint256 msb = BitMath.mostSignificantBit(r);

            if (msb >= 128) r = price >> (msb - 127);
            else r = price << (127 - msb);

            int256 log_2 = (int256(msb) - 128) << 64;

            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(63, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(62, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(61, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(60, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(59, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(58, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(57, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(56, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(55, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(54, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(53, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(52, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(51, f))
                r := shr(f, r)
            }
            assembly ("memory-safe") {
                r := shr(127, mul(r, r))
                let f := shr(128, r)
                log_2 := or(log_2, shl(50, f))
            }

            int256 log_sqrt10001 = log_2 * 255738958999603826347141; // Q22.128 数值。

            // 魔数表示近似 log_sqrt10001(x) 时最大误差值的上界。
            int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);

            // 当 sqrtPrice 位于 (2^-64, 2^64) 时，该魔数表示近似 log_sqrt10001(x) 的最小误差值。
            // MIN_SQRT_PRICE 大于 2^-64，因此此处安全；若修改 MIN_SQRT_PRICE，也可能需要同步修改该常量。
            int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);

            tick = tickLow == tickHi ? tickLow : getSqrtPriceAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
        }
    }
}
