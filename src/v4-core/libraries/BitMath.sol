// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title BitMath
/// @dev 提供计算无符号整数 bit 特征的函数，供 tick bitmap 等需要快速定位置位 bit 的逻辑使用。
/// @author Solady (https://github.com/Vectorized/solady/blob/8200a70e8dc2a77ecb074fc2e99a2a0d36547522/src/utils/LibBit.sol)
library BitMath {
    /// @notice 返回数值中最高有效 bit 的索引；最低有效 bit 索引为 0，最高为 255。
    /// @param x 要查找最高有效 bit 的数值，必须大于 0。
    /// @return r 最高有效 bit 的索引。
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            // forgefmt: disable-next-item
            r := or(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
                0x0706060506020500060203020504000106050205030304010505030400000000))
        }
    }

    /// @notice 返回数值中最低有效 bit 的索引；最低有效 bit 索引为 0，最高为 255。
    /// @param x 要查找最低有效 bit 的数值，必须大于 0。
    /// @return r 最低有效 bit 的索引。
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        assembly ("memory-safe") {
            // 利用 x & -x 单独保留最低有效 bit。
            x := and(x, sub(0, x))
            // 结果的高 3 bit 使用类似 De Bruijn 的查表方法计算。
            // 致谢 adhusson：https://blog.adhusson.com/cheap-find-first-set-evm/
            // forgefmt: disable-next-item
            r := shl(5, shr(252, shl(shl(2, shr(250, mul(x,
                0xb6db6db6ddddddddd34d34d349249249210842108c6318c639ce739cffffffff))),
                0x8040405543005266443200005020610674053026020000107506200176117077)))
            // 结果的低 5 bit 使用 De Bruijn 查表计算。
            // forgefmt: disable-next-item
            r := or(r, byte(and(div(0xd76453e0, shr(r, x)), 0x1f),
                0x001f0d1e100c1d070f090b19131c1706010e11080a1a141802121b1503160405))
        }
    }
}
