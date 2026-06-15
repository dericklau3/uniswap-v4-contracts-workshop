// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC6909} from "./ERC6909.sol";

/// @notice ERC6909Claims 继承 ERC6909，并补充可代表其他账户销毁 claim 的内部函数。
abstract contract ERC6909Claims is ERC6909 {
    /// @notice 从 `from` 账户销毁 `amount` 数量、资产类型为 `id` 的 token。
    /// @dev 当调用者不是 `from` 时，调用者必须是其 operator，或拥有足够的对应 `id` allowance。
    ///      在 Uniswap V4 中，`id` 通常由 Currency 地址转换而来，销毁 claim 表示用内部记账凭证偿还相应货币债务。
    /// @param from 被扣减并销毁 token 的账户。
    /// @param id 要销毁的货币/资产类型标识。
    /// @param amount 要销毁的数量。
    function _burnFrom(address from, uint256 id, uint256 amount) internal {
        address sender = msg.sender;
        if (from != sender && !isOperator[from][sender]) {
            uint256 senderAllowance = allowance[from][sender][id];
            if (senderAllowance != type(uint256).max) {
                allowance[from][sender][id] = senderAllowance - amount;
            }
        }
        _burn(from, id, amount);
    }
}
