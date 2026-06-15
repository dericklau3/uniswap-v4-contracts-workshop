// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice 使用 transient storage（tstore/tload）记录 PoolManager 本次交易内锁状态的临时工具库。
/// TODO: Solidity 支持 transient 关键字后可删除本库。
library Lock {
    // 瞬态保存 unlocked 状态的槽位：bytes32(uint256(keccak256("Unlocked")) - 1)。
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    function unlock() internal {
        assembly ("memory-safe") {
            // 标记为已解锁。
            tstore(IS_UNLOCKED_SLOT, true)
        }
    }

    function lock() internal {
        assembly ("memory-safe") {
            tstore(IS_UNLOCKED_SLOT, false)
        }
    }

    function isUnlocked() internal view returns (bool unlocked) {
        assembly ("memory-safe") {
            unlocked := tload(IS_UNLOCKED_SLOT)
        }
    }
}
