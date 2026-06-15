// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CustomRevert} from "./libraries/CustomRevert.sol";

/// @title 防止通过 delegatecall 调用合约
/// @notice 为子合约提供修饰器，阻止函数在其他合约的存储上下文中通过 delegatecall 执行。
abstract contract NoDelegateCall {
    using CustomRevert for bytes4;

    error DelegateCallNotAllowed();

    /// @dev 合约部署后自身的原始地址，用来与运行时的 `address(this)` 比较。
    address private immutable original;

    constructor() {
        // immutable 值在部署 init code 中计算，随后直接内联进运行时代码。
        // 因此运行时检查该变量时，它不会随着 delegatecall 的存储上下文改变。
        original = address(this);
    }

    /// @dev 使用 private 函数而不是把检查直接写入 modifier，是因为 modifier 会被复制到每个使用它的函数；
    ///      immutable 地址也会随之在每处重复嵌入。集中到此函数可减少部署字节码。
    function checkNotDelegateCall() private view {
        if (address(this) != original) DelegateCallNotAllowed.selector.revertWith();
    }

    /// @notice 阻止通过 delegatecall 进入使用该修饰器的函数。
    modifier noDelegateCall() {
        checkNotDelegateCall();
        _;
    }
}
