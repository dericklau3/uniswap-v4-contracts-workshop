// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 高效触发 custom error 的工具库
/// @notice 针对不同参数类型，以紧凑内存布局编码并触发 custom error。
/// @dev 使用时声明 `using CustomRevert for bytes4;`，并把 `revert CustomError()` 替换为
/// `CustomError.selector.revertWith()`
/// @dev 函数可能改动 free memory pointer，但随后会立即退出当前调用上下文，因此不会影响后续执行。
library CustomRevert {
    /// @dev 用于包装并向上冒泡下层回滚信息的 ERC-7751 error。
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    /// @dev 在 scratch space 中写入 custom error selector 并回滚。
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 0x04)
        }
    }

    /// @dev 在 scratch space 中编码带一个 address 参数的 custom error 并回滚。
    function revertWith(bytes4 selector, address addr) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev 在 scratch space 中编码带一个 int24 参数的 custom error 并回滚。
    function revertWith(bytes4 selector, int24 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, signextend(2, value))
            revert(0, 0x24)
        }
    }

    /// @dev 在 scratch space 中编码带一个 uint160 参数的 custom error 并回滚。
    function revertWith(bytes4 selector, uint160 value) internal pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(0x04, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(0, 0x24)
        }
    }

    /// @dev 编码带两个 int24 参数的 custom error 并回滚。
    function revertWith(bytes4 selector, int24 value1, int24 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), signextend(2, value1))
            mstore(add(fmp, 0x24), signextend(2, value2))
            revert(fmp, 0x44)
        }
    }

    /// @dev 编码带两个 uint160 参数的 custom error 并回滚。
    function revertWith(bytes4 selector, uint160 value1, uint160 value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @dev 编码带两个 address 参数的 custom error 并回滚。
    function revertWith(bytes4 selector, address value1, address value2) internal pure {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, selector)
            mstore(add(fmp, 0x04), and(value1, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x24), and(value2, 0xffffffffffffffffffffffffffffffffffffffff))
            revert(fmp, 0x44)
        }
    }

    /// @notice 将外部调用返回的回滚信息向上冒泡，并包装为 ERC-7751 error 后回滚。
    /// @dev 此方法可能受到 revert data bomb 影响：恶意目标可返回超大错误数据，导致复制数据消耗大量 gas。
    function bubbleUpAndRevertWith(
        address revertingContract,
        bytes4 revertingFunctionSelector,
        bytes4 additionalContext
    ) internal pure {
        bytes4 wrappedErrorSelector = WrappedError.selector;
        assembly ("memory-safe") {
            // 将回滚数据占用空间向上对齐到 32 byte 的整数倍。
            let encodedDataSize := mul(div(add(returndatasize(), 31), 32), 32)

            let fmp := mload(0x40)

            // 编码包装错误的 selector、目标地址、函数 selector、offset、附加上下文、长度与原始回滚原因。
            mstore(fmp, wrappedErrorSelector)
            mstore(add(fmp, 0x04), and(revertingContract, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(
                add(fmp, 0x24),
                and(revertingFunctionSelector, 0xffffffff00000000000000000000000000000000000000000000000000000000)
            )
            // 回滚原因的 offset。
            mstore(add(fmp, 0x44), 0x80)
            // 附加上下文的 offset。
            mstore(add(fmp, 0x64), add(0xa0, encodedDataSize))
            // 回滚原因长度。
            mstore(add(fmp, 0x84), returndatasize())
            // 原始回滚原因。
            returndatacopy(add(fmp, 0xa4), 0, returndatasize())
            // 附加上下文长度。
            mstore(add(fmp, add(0xa4, encodedDataSize)), 0x04)
            // 附加上下文。
            mstore(
                add(fmp, add(0xc4, encodedDataSize)),
                and(additionalContext, 0xffffffff00000000000000000000000000000000000000000000000000000000)
            )
            revert(fmp, add(0xe4, encodedDataSize))
        }
    }
}
