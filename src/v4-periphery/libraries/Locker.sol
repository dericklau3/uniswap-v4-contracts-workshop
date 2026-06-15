// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice 使用 `tstore/tload` 读写瞬时 locker 地址的临时库。
/// TODO：Solidity 原生支持 transient 关键字后可删除本库。
library Locker {
    // 瞬时保存 locker 的槽位：bytes32(uint256(keccak256("LockedBy")) - 1)。
    bytes32 constant LOCKED_BY_SLOT = 0x0aedd6bde10e3aa2adec092b02a3e3e805795516cda41f27aa145b8f300af87a;

    function set(address locker) internal {
        assembly {
            tstore(LOCKED_BY_SLOT, locker)
        }
    }

    function get() internal view returns (address locker) {
        assembly {
            locker := tload(LOCKED_BY_SLOT)
        }
    }
}
