// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice 使用 transient storage 实现 Universal Router 的执行锁。
/// @dev 不只保存布尔值，而是记录取得锁的外部调用者地址，使子计划自调用期间仍能恢复原始用户。
/// TODO: Solidity 原生支持 transient 关键字后，可删除本库并改用语言级瞬态状态变量。
library Locker {
    // 瞬态保存 locker 状态的槽位。bytes32(uint256(keccak256("Locker")) - 1)
    bytes32 constant LOCKER_SLOT = 0x0e87e1788ebd9ed6a7e63c70a374cd3283e41cad601d21fbe27863899ed4a708;

    function set(address locker) internal {
        // locker 始终是 `msg.sender` 或 `address(0)`，高位天然为零，无需额外清理槽数据。
        assembly ('memory-safe') {
            tstore(LOCKER_SLOT, locker)
        }
    }

    function get() internal view returns (address locker) {
        assembly ('memory-safe') {
            locker := tload(LOCKER_SLOT)
        }
    }

    function isLocked() internal view returns (bool) {
        return Locker.get() != address(0);
    }
}
