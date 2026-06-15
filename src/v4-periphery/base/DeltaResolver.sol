// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

/// @notice 负责读取、领取和结清 `PoolManager` 瞬时货币 delta 的抽象资金结算组件。
/// @dev V4 操作先在内部账本形成正负 delta：负值表示本合约欠池子资金，正值表示池子欠本合约资金。
/// `settle` 对 ERC-20 必须先调用 `sync()` 记录转账前余额，再转币并确认到账差额；原生币则随 `settle` 发送。
abstract contract DeltaResolver is ImmutableState {
    using TransientStateLibrary for IPoolManager;

    /// @notice 预期读取正向信用额，却发现负 delta 时回退。
    error DeltaNotPositive(Currency currency);
    /// @notice 预期读取待偿债务，却发现正 delta 时回退。
    error DeltaNotNegative(Currency currency);
    /// @notice 本合约余额不足以完成包装或解包时回退。
    error InsufficientBalance();

    /// @notice 从 `PoolManager` 领取本合约已获得的正向信用额。
    /// @param currency 要领取的货币。
    /// @param recipient 接收货币的地址。
    /// @param amount 领取数量。
    /// @dev 数量为 0 时直接返回；调用方应确保该数量不超过当前正 delta。
    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.take(currency, recipient, amount);
    }

    /// @notice 向 `PoolManager` 支付货币并结清对应负 delta。
    /// @dev 实现合约必须保证 `payer` 来源可信且已经授权；否则攻击者可能把无关地址指定为付款方。
    /// ERC-20 路径先 `sync`，再由 `_pay` 转入，最后 `settle` 按余额增量记账。
    /// @param currency 要结算的货币。
    /// @param payer 实际承担付款的地址。
    /// @param amount 支付数量；为 0 时直接返回。
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            _pay(currency, payer, amount);
            poolManager.settle();
        }
    }

    /// @notice 由继承合约实现 ERC-20 向 `PoolManager` 的实际付款方式。
    /// @dev 收款方必须是 `poolManager`；可根据集成方式使用 Permit2、普通 `transferFrom` 或合约自有余额。
    /// @param token 要结算的 ERC-20，已知不是原生币。
    /// @param payer 应承担代币支出的地址。
    /// @param amount 要发送的代币数量。
    function _pay(Currency token, address payer, uint256 amount) internal virtual;

    /// @notice 读取本合约对某种货币尚未结清的全部债务，即负 delta 的绝对值。
    /// @param currency 要查询的货币。
    /// @return amount 本合约应付数量，以无符号整数返回。
    function _getFullDebt(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // 正 delta 是可领取信用额，不能按债务结算。
        if (_amount > 0) revert DeltaNotNegative(currency);
        // 单池可记账总量受供应量边界约束，取负后转换为 uint256 是安全的。
        amount = uint256(-_amount);
    }

    /// @notice 读取 `PoolManager` 应付给本合约的全部信用额，即正 delta。
    /// @param currency 要查询的货币。
    /// @return amount 本合约可领取数量，以无符号整数返回。
    function _getFullCredit(Currency currency) internal view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // 负 delta 是待偿债务，不能按信用额领取。
        if (_amount < 0) revert DeltaNotPositive(currency);
        amount = uint256(_amount);
    }

    /// @notice 将结算动作中的特殊数量常量解析为合约余额、全部未结债务或显式数量。
    function _mapSettleAmount(uint256 amount, Currency currency) internal view virtual returns (uint256) {
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            return currency.balanceOfSelf();
        } else if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullDebt(currency);
        } else {
            return amount;
        }
    }

    /// @notice 将领取动作中的 `OPEN_DELTA` 解析为全部信用额，否则保留显式数量。
    function _mapTakeAmount(uint256 amount, Currency currency) internal view returns (uint256) {
        if (amount == ActionConstants.OPEN_DELTA) {
            return _getFullCredit(currency);
        } else {
            return amount;
        }
    }

    /// @notice 在包装或解包原生币前解析特殊数量并校验本合约真实余额。
    /// @param inputCurrency 本合约当前持有的输入货币，即原生币或包装原生币。
    /// @param amount 要包装或解包的数量，可以是 `CONTRACT_BALANCE`、`OPEN_DELTA` 或显式数量。
    /// @param outputCurrency 转换后的货币；本合约可能正好需要用它结清 `PoolManager` 中的负 delta。
    function _mapWrapUnwrapAmount(Currency inputCurrency, uint256 amount, Currency outputCurrency)
        internal
        view
        returns (uint256)
    {
        // 包装时输入余额是 ETH；解包时输入余额是 WETH。
        uint256 balance = inputCurrency.balanceOf(address(this));
        if (amount == ActionConstants.CONTRACT_BALANCE) {
            // 已直接采用全部余额，无需再做 amount > balance 的重复校验。
            return balance;
        }
        if (amount == ActionConstants.OPEN_DELTA) {
            // 包装时待关闭的 PoolManager 货币是 WETH；解包时则是 ETH。
            // 此处读取的是债务额。正 delta 应先领取，再视业务需要进行包装或解包。
            amount = _getFullDebt(outputCurrency);
        }
        if (amount > balance) revert InsufficientBalance();
        return amount;
    }
}
