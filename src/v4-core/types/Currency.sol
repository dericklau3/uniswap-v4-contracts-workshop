// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "../interfaces/external/IERC20Minimal.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";

type Currency is address;

using {greaterThan as >, lessThan as <, greaterThanOrEqualTo as >=, equals as ==} for Currency global;
using CurrencyLibrary for Currency global;

function equals(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) == Currency.unwrap(other);
}

function greaterThan(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) > Currency.unwrap(other);
}

function lessThan(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) < Currency.unwrap(other);
}

function greaterThanOrEqualTo(Currency currency, Currency other) pure returns (bool) {
    return Currency.unwrap(currency) >= Currency.unwrap(other);
}

/// @title CurrencyLibrary
/// @dev 统一封装原生币与 ERC20 token 的转账、余额查询和标识转换。
library CurrencyLibrary {
    /// @notice 原生币转账失败时，为 ERC-7751 包装错误提供附加上下文。
    error NativeTransferFailed();

    /// @notice ERC20 转账失败时，为 ERC-7751 包装错误提供附加上下文。
    error ERC20TransferFailed();

    /// @notice 用零地址表示原生货币的常量。
    Currency public constant ADDRESS_ZERO = Currency.wrap(address(0));

    function transfer(Currency currency, address to, uint256 amount) internal {
        // 改写自 https://github.com/transmissions11/solmate/blob/44a9963d4c78111f77caa0e65d677b8b46d6f2e6/src/utils/SafeTransferLib.sol
        // 此处修改了 custom error selector。

        bool success;
        if (currency.isAddressZero()) {
            assembly ("memory-safe") {
                // 转出 ETH，并在调用失败时回滚。
                success := call(gas(), to, amount, 0, 0, 0, 0)
            }
            // 使用 NativeTransferFailed 回滚，并把下层调用的错误数据作为参数向上冒泡。
            if (!success) {
                CustomRevert.bubbleUpAndRevertWith(to, bytes4(0), NativeTransferFailed.selector);
            }
        } else {
            assembly ("memory-safe") {
                // 取得空闲内存指针。
                let fmp := mload(0x40)

                // 从函数 selector 开始，把 ABI 编码后的 calldata 写入内存。
                mstore(fmp, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
                mstore(add(fmp, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // 追加并掩码处理 "to" 参数。
                mstore(add(fmp, 36), amount) // 追加 "amount" 参数；完整 32 byte 类型不需要掩码。

                success :=
                    and(
                        // 若调用未回滚，则要求返回值严格等于 1（不能只是非零），或者完全没有返回数据。
                        or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                        // calldata 总长度为 4 + 32 * 2，因此这里使用 68。
                        // 使用 0 和 32，把最多 32 byte 返回数据复制到 scratch space。
                        // 注意：该 call 必须放在外围 and() 中 or() 的第二个操作数位置，
                        // 否则计算前读取到的 returndatasize() 会是 0。
                        call(gas(), currency, 0, fmp, 68, 0, 32)
                    )

                // 清理刚才使用的内存。
                mstore(fmp, 0) // 此处曾存放 4 byte `selector` 和 `to` 的前 28 byte。
                mstore(add(fmp, 0x20), 0) // 此处曾存放 `to` 的后 4 byte 和 `amount` 的前 28 byte。
                mstore(add(fmp, 0x40), 0) // 此处曾存放 `amount` 的后 4 byte。
            }
            // 使用 ERC20TransferFailed 回滚，并把下层 token 调用的错误数据作为参数向上冒泡。
            if (!success) {
                CustomRevert.bubbleUpAndRevertWith(
                    Currency.unwrap(currency), IERC20Minimal.transfer.selector, ERC20TransferFailed.selector
                );
            }
        }
    }

    function balanceOfSelf(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return address(this).balance;
        } else {
            return IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
        }
    }

    function balanceOf(Currency currency, address owner) internal view returns (uint256) {
        if (currency.isAddressZero()) {
            return owner.balance;
        } else {
            return IERC20Minimal(Currency.unwrap(currency)).balanceOf(owner);
        }
    }

    function isAddressZero(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == Currency.unwrap(ADDRESS_ZERO);
    }

    function toId(Currency currency) internal pure returns (uint256) {
        return uint160(Currency.unwrap(currency));
    }

    // 若高 12 byte 非零，转换为 address 时会被截断清零。
    // 因此 fromId() 与 toId() 并不总是互为逆运算。
    function fromId(uint256 id) internal pure returns (Currency) {
        return Currency.wrap(address(uint160(id)));
    }
}
