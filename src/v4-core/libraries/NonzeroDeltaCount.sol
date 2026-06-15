// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice 使用 transient storage（tstore/tload）记录非零 currency delta 数量的临时工具库。
/// @dev unlock 回调结束前该计数必须回到 0，证明所有货币债权债务都已结清。
/// TODO: Solidity 支持 transient 关键字后可删除本库。
library NonzeroDeltaCount {
    // 保存非零 delta 数量的槽位：bytes32(uint256(keccak256("NonzeroDeltaCount")) - 1)。
    bytes32 internal constant NONZERO_DELTA_COUNT_SLOT =
        0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;

    function read() internal view returns (uint256 count) {
        assembly ("memory-safe") {
            count := tload(NONZERO_DELTA_COUNT_SLOT)
        }
    }

    function increment() internal {
        assembly ("memory-safe") {
            let count := tload(NONZERO_DELTA_COUNT_SLOT)
            count := add(count, 1)
            tstore(NONZERO_DELTA_COUNT_SLOT, count)
        }
    }

    /// @notice 此函数存在下溢可能，集成合约必须在调用流程中保证计数不会被过度扣减。
    /// @dev 当前使用方式有明确边界：decrement 的调用次数不会超过此前 increment 的调用次数，因此不会下溢。
    function decrement() internal {
        assembly ("memory-safe") {
            let count := tload(NONZERO_DELTA_COUNT_SLOT)
            count := sub(count, 1)
            tstore(NONZERO_DELTA_COUNT_SLOT, count)
        }
    }
}
