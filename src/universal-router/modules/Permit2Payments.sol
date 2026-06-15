// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from 'permit2/src/interfaces/IAllowanceTransfer.sol';
import {SafeCast160} from 'permit2/src/libraries/SafeCast160.sol';
import {Payments} from './Payments.sol';

/// @title Permit2 支付模块
/// @notice 通过 Permit2 从用户拉取 ERC20，并在“用户付款”与“路由器余额付款”之间统一选择资金来源。
abstract contract Permit2Payments is Payments {
    using SafeCast160 for uint256;

    error FromAddressIsNotOwner();

    /// @notice 通过 Permit2 执行单笔 `transferFrom`。
    /// @param token 待转移的 ERC20。
    /// @param from 代币所有者及付款地址。
    /// @param to 收款地址，通常是 V2 Pair、V3 Pool、V4 PoolManager 或路由器。
    /// @param amount 转移数量，受 Permit2 的 uint160 额度限制。
    function permit2TransferFrom(address token, address from, address to, uint160 amount) internal {
        PERMIT2.transferFrom(from, to, amount, token);
    }

    /// @notice 通过 Permit2 批量执行多笔 `transferFrom`。
    /// @dev 每一项的 `from` 都必须等于同一个路由用户，防止命令输入夹带其他所有者的授权转账。
    /// @param batchDetails 描述每笔代币、来源、接收者与数量的转账数组。
    /// @param owner 所有批量转账必须使用的代币所有者。
    function permit2TransferFrom(IAllowanceTransfer.AllowanceTransferDetails[] calldata batchDetails, address owner)
        internal
    {
        uint256 batchLength = batchDetails.length;
        for (uint256 i = 0; i < batchLength; ++i) {
            if (batchDetails[i].from != owner) revert FromAddressIsNotOwner();
        }
        PERMIT2.transferFrom(batchDetails);
    }

    /// @notice 根据付款方决定从路由器现有余额支付，还是通过 Permit2 从用户拉款。
    /// @dev 多 hop 的中间资产通常由路由器托管，因此 `payer == address(this)` 时直接调用 `pay`；
    /// 首跳由用户付款时则走 Permit2，避免每个路由模块重复实现付款分支。
    /// @param token 待支付的 ERC20。
    /// @param payer 付款地址；路由器自身表示使用合约余额。
    /// @param recipient 收款地址。
    /// @param amount 支付数量。
    function payOrPermit2Transfer(address token, address payer, address recipient, uint256 amount) internal {
        if (payer == address(this)) pay(token, recipient, amount);
        else permit2TransferFrom(token, payer, recipient, amount.toUint160());
    }
}
