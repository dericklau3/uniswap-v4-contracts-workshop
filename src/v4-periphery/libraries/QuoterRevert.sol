// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ParseBytes} from "@uniswap/v4-core/src/libraries/ParseBytes.sol";

library QuoterRevert {
    using QuoterRevert for bytes;
    using ParseBytes for bytes;

    /// @notice 报价回退数据不是预期 `QuoteSwap` 格式时抛出。
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice 用错误参数携带报价金额，供外层 try/catch 捕获和解析。
    error QuoteSwap(uint256 amount);

    /// @notice 主动回退并把报价金额编码进 `QuoteSwap`。
    /// @dev 报价模拟用回退回滚全部状态；专用 selector 可将成功报价与真实模拟错误区分开。
    function revertQuote(uint256 quoteAmount) internal pure {
        revert QuoteSwap(quoteAmount);
    }

    /// @notice 使用原始 `revertData` 作为原因重新回退。
    /// @dev 既可上传合法 `QuoteSwap(amount)`，也可保留模拟期间产生的其他错误。
    function bubbleReason(bytes memory revertData) internal pure {
        // mload(revertData) 是数据长度；add(revertData, 0x20) 指向实际数据起点。
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice 验证回退原因是否为合法兑换报价；合法则解码金额，否则继续回退。
    function parseQuoteAmount(bytes memory reason) internal pure returns (uint256 quoteAmount) {
        // selector 不是 QuoteSwap 时，说明模拟在其他位置真实失败，不能把它误当成报价结果。
        if (reason.parseSelector() != QuoteSwap.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason 到 reason+0x1f 为 bytes 长度；
        // reason+0x20 到 reason+0x23 为 QuoteSwap selector；
        // reason+0x24 到 reason+0x43 为 quoteAmount。
        assembly ("memory-safe") {
            quoteAmount := mload(add(reason, 0x24))
        }
    }
}
