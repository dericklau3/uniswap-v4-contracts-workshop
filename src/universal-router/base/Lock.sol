// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Locker} from '../libraries/Locker.sol';

/// @title Universal Router 执行锁
/// @notice 为外部执行入口提供防重入保护，同时允许路由器通过自调用执行嵌套子计划。
contract Lock {
    /// @notice 外部调用者试图重入已经上锁的执行流程时抛出。
    error ContractLocked();

    /// @notice 对外部调用加锁，但允许 `address(this)` 为执行子计划而自重入。
    /// @dev 第一次进入时把 `msg.sender` 记录为 locker；后续模块即使处于合约自调用中，也可通过
    /// `_getLocker()` 恢复真正发起整条路由的用户地址。
    modifier isNotLocked() {
        // 外部入口必须取得锁，并在整个命令序列完成后释放。
        if (msg.sender != address(this)) {
            if (Locker.isLocked()) revert ContractLocked();
            Locker.set(msg.sender);
            _;
            Locker.set(address(0));
        } else {
            // 自调用来自 `EXECUTE_SUB_PLAN`，属于同一受保护执行链，因此允许继续进入。
            _;
        }
    }

    /// @notice 返回当前执行链最初取得锁的调用者。
    /// @return 当前路由用户；未上锁时为 `address(0)`。
    function _getLocker() internal view returns (address) {
        return Locker.get();
    }
}
