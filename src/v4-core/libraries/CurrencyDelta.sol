// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Currency} from "../types/Currency.sol";

/// @title 在瞬态存储中记录调用方货币差额的工具库。
/// @dev 由于 transient storage 只能在 assembly 中访问，本库用哈希槽位实现等价于
///      `mapping(address => mapping(Currency => int256))` 的交易内记账。
library CurrencyDelta {
    /// @notice 计算指定账户与货币的 delta 应存放在哪个瞬态存储槽位。
    function _computeSlot(address target, Currency currency) internal pure returns (bytes32 hashSlot) {
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            hashSlot := keccak256(0, 64)
        }
    }

    function getDelta(Currency currency, address target) internal view returns (int256 delta) {
        bytes32 hashSlot = _computeSlot(target, currency);
        assembly ("memory-safe") {
            delta := tload(hashSlot)
        }
    }

    /// @notice 把新的差额变化应用到指定账户和货币的交易内余额。
    /// @dev V4 unlock 流程允许操作先发生、资金后统一结算；该值从非零变为零或反向变化时，
    ///      上层还会同步维护未结清差额计数。
    /// @return previous 修改前的累计差额。
    /// @return next 应用 `delta` 后的累计差额。
    function applyDelta(Currency currency, address target, int128 delta)
        internal
        returns (int256 previous, int256 next)
    {
        bytes32 hashSlot = _computeSlot(target, currency);

        assembly ("memory-safe") {
            previous := tload(hashSlot)
        }
        next = previous + delta;
        assembly ("memory-safe") {
            tstore(hashSlot, next)
        }
    }
}
