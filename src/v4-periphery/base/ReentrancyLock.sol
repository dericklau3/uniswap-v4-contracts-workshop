// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Locker} from "../libraries/Locker.sol";

/// @notice 使用瞬时存储实现的重入锁，并把原始调用者地址同时保存为当前 locker。
contract ReentrancyLock {
    error ContractLocked();

    modifier isNotLocked() {
        if (Locker.get() != address(0)) revert ContractLocked();
        Locker.set(msg.sender);
        _;
        Locker.set(address(0));
    }

    function _getLocker() internal view returns (address) {
        return Locker.get();
    }
}
