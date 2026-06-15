// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice 处理协议费打包、方向读取、有效性检查与总兑换费计算的工具库。
library ProtocolFeeLibrary {
    /// @notice 协议费上限为 0.1%（1000 pips）。
    /// @dev 提高该上限可能导致 Pool.swap 中的计算溢出。
    uint16 public constant MAX_PROTOCOL_FEE = 1000;

    /// @notice 用于优化协议费边界检查的阈值。
    uint24 internal constant FEE_0_THRESHOLD = 1001;
    uint24 internal constant FEE_1_THRESHOLD = 1001 << 12;

    /// @notice 协议费以百分之一 bip 表示。
    uint256 internal constant PIPS_DENOMINATOR = 1_000_000;

    function getZeroForOneFee(uint24 self) internal pure returns (uint16) {
        return uint16(self & 0xfff);
    }

    function getOneForZeroFee(uint24 self) internal pure returns (uint16) {
        return uint16(self >> 12);
    }

    function isValidProtocolFee(uint24 self) internal pure returns (bool valid) {
        // 等价于：getZeroForOneFee(self) <= MAX_PROTOCOL_FEE && getOneForZeroFee(self) <= MAX_PROTOCOL_FEE
        assembly ("memory-safe") {
            let isZeroForOneFeeOk := lt(and(self, 0xfff), FEE_0_THRESHOLD)
            let isOneForZeroFeeOk := lt(and(self, 0xfff000), FEE_1_THRESHOLD)
            valid := and(isZeroForOneFeeOk, isOneForZeroFeeOk)
        }
    }

    // 先从输入金额中扣除协议费，再从剩余输入中扣除 LP fee。
    // 总 swap fee 上限为 100%。
    // 等价于 protocolFee + lpFee(1_000_000 - protocolFee) / 1_000_000（向上取整）。
    /// @dev 此处 `self` 只是单一兑换方向的协议费，不是打包了两个方向费率的 uint24。
    function calculateSwapFee(uint16 self, uint24 lpFee) internal pure returns (uint24 swapFee) {
        // protocolFee + lpFee - (protocolFee * lpFee / 1_000_000)
        assembly ("memory-safe") {
            self := and(self, 0xfff)
            lpFee := and(lpFee, 0xffffff)
            let numerator := mul(self, lpFee)
            swapFee := sub(add(self, lpFee), div(numerator, PIPS_DENOMINATOR))
        }
    }
}
