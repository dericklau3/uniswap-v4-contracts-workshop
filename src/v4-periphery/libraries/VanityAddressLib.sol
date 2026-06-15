// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 靓号地址评分库
/// @notice 按 V4 视觉规则为地址评分，并比较哪个 CREATE2 候选地址更优。
library VanityAddressLib {
    /// @notice 比较两个地址的靓号得分。
    /// @param first 第一个地址。
    /// @param second 第二个地址。
    /// @return better 第一个地址得分更高时为 true。
    function betterThan(address first, address second) internal pure returns (bool better) {
        return score(first) > score(second);
    }

    /// @notice 按靓号规则计算地址得分。
    /// @dev 规则：
    ///    硬性要求：第一个非零 nibble 必须是 4；
    ///    每个前导 0 nibble 得 10 分；
    ///    开头连续出现四个 4 时获得额外分；
    ///    末尾四个 nibble 全为 4 时加 20 分；
    ///    地址中每个 4 另加 1 分。
    /// @param addr 要评分的地址。
    /// @return calculatedScore 地址靓号得分。
    function score(address addr) internal pure returns (uint256 calculatedScore) {
        // 转为 bytes20，便于逐个半字节解析。
        bytes20 addrBytes = bytes20(addr);

        unchecked {
            // 每个前导零半字节计 10 分。
            uint256 leadingZeroCount = getLeadingNibbleCount(addrBytes, 0, 0);
            calculatedScore += (leadingZeroCount * 10);

            // 单独统计前导零之后连续出现的 4。
            uint256 leadingFourCount = getLeadingNibbleCount(addrBytes, leadingZeroCount, 4);
            // 第一个非零半字节不是 4 时不符合竞赛地址模式，得分为 0。
            if (leadingFourCount == 0) {
                return 0;
            } else if (leadingFourCount == 4) {
                // 恰好连续四个 4 时加 60 分。
                calculatedScore += 60;
            } else if (leadingFourCount > 4) {
                // 连续超过四个 4 时加 40 分。
                calculatedScore += 40;
            }

            // 遍历全部半字节累计普通 4 奖励。
            for (uint256 i = 0; i < addrBytes.length * 2; i++) {
                uint8 currentNibble = getNibble(addrBytes, i);

                // 每出现一个 4 额外加 1 分。
                if (currentNibble == 4) {
                    calculatedScore += 1;
                }
            }

            // 地址末尾四个半字节均为 4 时加 20 分。
            if (addrBytes[18] == 0x44 && addrBytes[19] == 0x44) {
                calculatedScore += 20;
            }
        }
    }

    /// @notice 从指定位置起统计连续等于目标值的半字节数量。
    /// @param addrBytes 要扫描的地址字节。
    function getLeadingNibbleCount(bytes20 addrBytes, uint256 startIndex, uint8 comparison)
        internal
        pure
        returns (uint256 count)
    {
        if (startIndex >= addrBytes.length * 2) {
            return count;
        }

        for (uint256 i = startIndex; i < addrBytes.length * 2; i++) {
            uint8 currentNibble = getNibble(addrBytes, i);
            if (currentNibble != comparison) {
                return count;
            }
            count += 1;
        }
    }

    /// @notice 返回地址指定索引处的半字节。
    /// @param input 地址字节。
    /// @param nibbleIndex 半字节索引，0 表示首字节高 4 位。
    function getNibble(bytes20 input, uint256 nibbleIndex) internal pure returns (uint8 currentNibble) {
        uint8 currByte = uint8(input[nibbleIndex / 2]);
        if (nibbleIndex % 2 == 0) {
            // 偶数索引取当前字节高 4 位。
            currentNibble = currByte >> 4;
        } else {
            // 奇数索引取当前字节低 4 位。
            currentNibble = currByte & 0x0F;
        }
    }
}
