// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BitMath} from "./BitMath.sol";

/// @title 打包存储 tick 初始化状态的工具库
/// @notice 用 bitmap 保存每个可用 tick 是否已初始化，使 swap 能快速寻找下一条流动性边界。
/// @dev tick 使用 int24 表示，每个 uint256 word 保存 256（2^8）个压缩 tick，因此 mapping 键只需 int16。
library TickBitmap {
    /// @notice tick 不是 tickSpacing 的整数倍时抛出。
    /// @param tick 无效的 tick。
    /// @param tickSpacing 池的 tick 间距。
    error TickMisaligned(int24 tick, int24 tickSpacing);

    /// @dev 将 tick 除以 tickSpacing，并向负无穷方向取整。
    function compress(int24 tick, int24 tickSpacing) internal pure returns (int24 compressed) {
        // compressed = tick / tickSpacing;
        // if (tick < 0 && tick % tickSpacing != 0) compressed--;
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            compressed :=
                sub(
                    sdiv(tick, tickSpacing),
                    // 若 tick < 0 且不能整除 tickSpacing，则余数为负，需要额外减 1 才是向负无穷取整。
                    slt(smod(tick, tickSpacing), 0)
                )
        }
    }

    /// @notice 计算某个压缩 tick 的初始化标志位于 mapping 中的哪个 word 和哪个 bit。
    /// @param tick 要定位的压缩 tick。
    /// @return wordPos 保存该 bit 的 mapping 键。
    /// @return bitPos 标志在 uint256 word 内的 bit 位置。
    function position(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            // 有符号算术右移 8 位，得到每 256 个 tick 一组的 wordPos。
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }

    /// @notice 翻转指定 tick 的初始化状态：false 变 true，或 true 变 false。
    /// @dev 仓位第一次引用某边界时将其置为已初始化；最后一个引用该边界的仓位移除后再清除。
    /// @param self 保存 tick 初始化状态的 mapping。
    /// @param tick 要翻转的实际 tick。
    /// @param tickSpacing 可用 tick 之间的间距。
    function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) internal {
        // 等价于以下 Solidity：
        //     if (tick % tickSpacing != 0) revert TickMisaligned(tick, tickSpacing);
        //     (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        //     uint256 mask = 1 << bitPos;
        //     self[wordPos] ^= mask;
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            // 确保 tick 与 tickSpacing 对齐。
            if smod(tick, tickSpacing) {
                let fmp := mload(0x40)
                mstore(fmp, 0xd4d8f3e6) // TickMisaligned(int24,int24) 的 selector。
                mstore(add(fmp, 0x20), tick)
                mstore(add(fmp, 0x40), tickSpacing)
                revert(add(fmp, 0x1c), 0x44)
            }
            tick := sdiv(tick, tickSpacing)
            // 计算该压缩 tick 对应的存储槽位。
            // wordPos = tick >> 8
            mstore(0, sar(8, tick))
            mstore(0x20, self.slot)
            // self[wordPos] 的槽位是 keccak256(abi.encode(wordPos, self.slot))。
            let slot := keccak256(0, 0x40)
            // mask = 1 << bitPos = 1 << (tick % 256)
            // self[wordPos] ^= mask
            sstore(slot, xor(sload(slot), shl(and(tick, 0xff), 1)))
        }
    }

    /// @notice 在当前 tick 所在 word 或紧邻 word 中，寻找左侧（小于等于）或右侧（大于）的下一条已初始化 tick。
    /// @dev 单次只扫描一个 256 bit word。若该方向没有已初始化 bit，则返回该 word 的边界 tick，
    ///      并令 initialized=false；swap 循环随后可从该边界继续扫描下一 word。
    /// @param self 保存 tick 初始化状态的 mapping。
    /// @param tick 搜索起点的实际 tick。
    /// @param tickSpacing 可用 tick 之间的间距。
    /// @param lte true 表示向左搜索小于等于起点的 tick，false 表示向右搜索严格大于起点的 tick。
    /// @return next 距当前 tick 最多 256 个压缩 tick 的下一搜索结果。
    /// @return initialized 返回的 next 是否确实是已初始化 tick。
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = position(compressed);
                // mask 保留当前 bitPos 及其右侧（更低索引）的所有 bit。
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = self[wordPos] & mask;

                // 若当前 bit 及其右侧没有已初始化 tick，则返回该 word 最右侧边界。
                initialized = masked != 0;
                // 理论上可能上溢/下溢，但外部对 tickSpacing 与 tick 的范围限制会阻止这种情况。
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                // 向右搜索必须从下一个压缩 tick 开始，因为当前 tick 状态不应被重复命中。
                (int16 wordPos, uint8 bitPos) = position(++compressed);
                // mask 保留 bitPos 及其左侧（更高索引）的所有 bit。
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = self[wordPos] & mask;

                // 若 bitPos 及其左侧没有已初始化 tick，则返回该 word 最左侧边界。
                initialized = masked != 0;
                // 理论上可能上溢/下溢，但外部对 tickSpacing 与 tick 的范围限制会阻止这种情况。
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }
}
