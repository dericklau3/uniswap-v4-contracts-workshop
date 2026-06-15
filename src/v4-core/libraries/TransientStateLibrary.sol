// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {Currency} from "../types/Currency.sol";
import {CurrencyReserves} from "./CurrencyReserves.sol";
import {NonzeroDeltaCount} from "./NonzeroDeltaCount.sol";
import {Lock} from "./Lock.sol";

/// @notice 通过 exttload 读取 PoolManager 瞬态状态的辅助库。
library TransientStateLibrary {
    /// @notice 返回当前已 sync 货币的余额快照。
    /// @param manager PoolManager 合约。
    /// @return uint256 该货币在 sync 时记录的储备余额。
    /// @dev 若当前没有同步货币或快照值为 0，则返回 0。通过检查 synced currency，
    ///      保证只在 sync 之后、settle 之前返回有效储备值。
    function getSyncedReserves(IPoolManager manager) internal view returns (uint256) {
        if (getSyncedCurrency(manager).isAddressZero()) return 0;
        return uint256(manager.exttload(CurrencyReserves.RESERVES_OF_SLOT));
    }

    function getSyncedCurrency(IPoolManager manager) internal view returns (Currency) {
        return Currency.wrap(address(uint160(uint256(manager.exttload(CurrencyReserves.CURRENCY_SLOT)))));
    }

    /// @notice 返回 PoolManager 当前未结清的非零 delta 数量；重新上锁前该值必须归零。
    function getNonzeroDeltaCount(IPoolManager manager) internal view returns (uint256) {
        return uint256(manager.exttload(NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT));
    }

    /// @notice 查询某账户在指定货币上的当前交易内差额。
    /// @param target 被记账的账户地址。
    /// @param currency 要查询差额的货币。
    function currencyDelta(IPoolManager manager, address target, Currency currency) internal view returns (int256) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
        return int256(uint256(manager.exttload(key)));
    }

    /// @notice 返回 PoolManager 当前是否处于 unlocked 状态。
    function isUnlocked(IPoolManager manager) internal view returns (bool) {
        return manager.exttload(Lock.IS_UNLOCKED_SLOT) != 0x0;
    }
}
