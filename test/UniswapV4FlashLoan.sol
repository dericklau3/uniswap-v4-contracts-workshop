// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {CurrencySettler} from "./CurrencySettler.sol";

/// @notice 自定义 V4 闪电贷逻辑回调接口。
interface IUniswapV4FlashLoanCallback {
    /// @notice 收到借出资产后执行自定义逻辑，并在返回前把本金和利息留在 flash loan 合约中。
    function uniswapV4FlashLoanCallback(
        address initiator,
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}

/// @title Uniswap V4 flash-accounting flash loan template
/// @notice 从指定 V4 pool 借出单个 token，执行自定义逻辑，归还本金与通过 donate 支付的利息，并转出剩余盈利。
/// @dev V4 没有 V3 pool.flash()；模板使用 PoolManager.unlock() 期间的 take/settle 闪电记账实现。
contract UniswapV4FlashLoan is SafeCallback, Ownable2Step {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 public constant BIPS_DENOMINATOR = 10_000;

    error InvalidParameter();
    error InvalidFlashLoanAmount();
    error FlashLoanInProgress();
    error UnexpectedCallback();
    error InsufficientRepaymentBalance();

    event FlashLoanStarted(
        address indexed initiator,
        bytes32 indexed poolId,
        Currency indexed currency,
        uint256 amount,
        uint256 fee,
        address callbackTarget
    );
    event FlashLoanRepaid(Currency indexed currency, uint256 amount, uint256 fee, uint256 profit);

    struct FlashLoanData {
        PoolKey key;
        Currency currency;
        uint256 amount;
        uint256 fee;
        address initiator;
        address callbackTarget;
        bytes callbackData;
    }

    address public immutable profitRecipient;
    uint256 public immutable premiumBips;

    bool private flashLoanActive;

    constructor(IPoolManager _poolManager, address initialOwner, address _profitRecipient, uint256 _premiumBips)
        SafeCallback(_poolManager)
        Ownable(initialOwner)
    {
        if (_profitRecipient == address(0) || _premiumBips > BIPS_DENOMINATOR) revert InvalidParameter();
        profitRecipient = _profitRecipient;
        premiumBips = _premiumBips;
    }

    receive() external payable {}

    /// @notice 发起 V4 flash-accounting 借款。
    /// @param key 指定用于校验和收取利息的 V4 pool。
    /// @param currency 要借出的单个 token，必须是 key.currency0 或 key.currency1。
    /// @param amount 借出数量。
    /// @param callbackTarget 执行自定义逻辑的合约，需实现 IUniswapV4FlashLoanCallback。
    /// @param callbackData 传给 callbackTarget 的自定义数据。
    function startFlashLoan(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        address callbackTarget,
        bytes calldata callbackData
    ) external onlyOwner returns (bytes memory result) {
        if (flashLoanActive) revert FlashLoanInProgress();
        if (amount == 0) revert InvalidFlashLoanAmount();
        if (callbackTarget == address(0)) revert InvalidParameter();
        if (!(currency == key.currency0) && !(currency == key.currency1)) revert InvalidParameter();

        uint256 fee = amount * premiumBips / BIPS_DENOMINATOR;
        flashLoanActive = true;
        emit FlashLoanStarted(msg.sender, PoolId.unwrap(PoolIdLibrary.toId(key)), currency, amount, fee, callbackTarget);

        result = poolManager.unlock(
            abi.encode(
                FlashLoanData({
                    key: key,
                    currency: currency,
                    amount: amount,
                    fee: fee,
                    initiator: msg.sender,
                    callbackTarget: callbackTarget,
                    callbackData: callbackData
                })
            )
        );

        flashLoanActive = false;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (!flashLoanActive) revert UnexpectedCallback();

        FlashLoanData memory loan = abi.decode(data, (FlashLoanData));
        uint256 balanceBefore = loan.currency.balanceOfSelf();
        loan.currency.take(poolManager, address(this), loan.amount, false);

        _callFlashLoanCallback(loan);

        uint256 repayment = loan.amount + loan.fee;
        if (loan.currency.balanceOfSelf() < repayment) revert InsufficientRepaymentBalance();

        if (loan.fee > 0) {
            if (loan.currency == loan.key.currency0) {
                poolManager.donate(loan.key, loan.fee, 0, new bytes(0));
            } else {
                poolManager.donate(loan.key, 0, loan.fee, new bytes(0));
            }
        }

        loan.currency.settle(poolManager, address(this), repayment, false);

        uint256 balanceAfter = loan.currency.balanceOfSelf();
        uint256 profit = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (profit > 0) {
            loan.currency.transfer(profitRecipient, profit);
        }

        emit FlashLoanRepaid(loan.currency, loan.amount, loan.fee, profit);
        return bytes("");
    }

    function _callFlashLoanCallback(FlashLoanData memory loan) private {
        (bool success, bytes memory returnData) = loan.callbackTarget
            .call(
                abi.encodeCall(
                    IUniswapV4FlashLoanCallback.uniswapV4FlashLoanCallback,
                    (loan.initiator, loan.key, loan.currency, loan.amount, loan.fee, loan.callbackData)
                )
            );

        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
