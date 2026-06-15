// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AddressStringUtil} from "./AddressStringUtil.sol";

/// @title 安全货币元数据
/// @notice 面对未实现标准接口、返回 bytes32 或返回异常数据的 ERC-20，仍安全生成 symbol 和 decimals。
/// @dev 参考：https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/SafeERC20Namer.sol
library SafeCurrencyMetadata {
    uint8 constant MAX_SYMBOL_LENGTH = 12;

    /// @notice 尝试读取货币 symbol；未实现或返回异常时，用地址前 6 个大写十六进制字符兜底。
    /// @param currency 货币地址，零地址表示原生币。
    /// @param nativeLabel 原生币展示标签。
    /// @return 可安全嵌入 NFT 元数据的货币符号。
    function currencySymbol(address currency, string memory nativeLabel) internal view returns (string memory) {
        if (currency == address(0)) {
            return nativeLabel;
        }
        string memory symbol = callAndParseStringReturn(currency, IERC20Metadata.symbol.selector);
        if (bytes(symbol).length == 0) {
            // symbol 不可用时，退回地址前 6 个大写十六进制字符。
            return addressToSymbol(currency);
        }
        if (bytes(symbol).length > MAX_SYMBOL_LENGTH) {
            return truncateSymbol(symbol);
        }
        return symbol;
    }

    /// @notice 尝试读取代币 decimals；未实现、调用失败或结果超出 uint8 时返回 0。
    /// @param currency 货币地址，零地址原生币按 18 位处理。
    /// @return 货币小数位数。
    function currencyDecimals(address currency) internal view returns (uint8) {
        if (currency == address(0)) {
            return 18;
        }
        (bool success, bytes memory data) = currency.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!success) {
            return 0;
        }
        if (data.length == 32) {
            uint256 decimals = abi.decode(data, (uint256));
            if (decimals <= type(uint8).max) {
                return uint8(decimals);
            }
        }
        return 0;
    }

    function bytes32ToString(bytes32 x) private pure returns (string memory) {
        bytes memory bytesString = new bytes(32);
        uint256 charCount = 0;
        for (uint256 j = 0; j < 32; j++) {
            bytes1 char = x[j];
            if (char != 0) {
                bytesString[charCount] = char;
                charCount++;
            }
        }
        bytes memory bytesStringTrimmed = new bytes(charCount);
        for (uint256 j = 0; j < charCount; j++) {
            bytesStringTrimmed[j] = bytesString[j];
        }
        return string(bytesStringTrimmed);
    }

    /// @notice 用货币地址前 6 个大写十六进制字符生成兜底 symbol。
    /// @param currencyAddress 货币地址。
    /// @return 兜底符号。
    function addressToSymbol(address currencyAddress) private pure returns (string memory) {
        return AddressStringUtil.toAsciiString(currencyAddress, 6);
    }

    /// @notice 静态调用返回符号的外部方法，并兼容 bytes32 与动态 string 两种常见返回格式。
    /// @param currencyAddress 货币地址。
    /// @param selector 元数据方法 selector。
    /// @return 解析后的符号；调用或格式无效时为空字符串。
    function callAndParseStringReturn(address currencyAddress, bytes4 selector) private view returns (string memory) {
        (bool success, bytes memory data) = currencyAddress.staticcall(abi.encodeWithSelector(selector));
        // 未实现或调用回退时返回空字符串，让上层采用地址兜底。
        if (!success) {
            return "";
        }
        // 老式代币常直接返回固定 32 字节符号。
        if (data.length == 32) {
            bytes32 decoded = abi.decode(data, (bytes32));
            return bytes32ToString(decoded);
        } else if (data.length > 64) {
            return abi.decode(data, (string));
        }
        return "";
    }

    /// @notice 将过长 symbol 截断到 `MAX_SYMBOL_LENGTH`，防止破坏 NFT SVG/JSON 布局。
    /// @dev 假设输入长度已经大于或等于最大长度。
    /// @param str 原始符号。
    /// @return 截断后的符号。
    function truncateSymbol(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory truncatedBytes = new bytes(MAX_SYMBOL_LENGTH);
        for (uint256 i = 0; i < MAX_SYMBOL_LENGTH; i++) {
            truncatedBytes[i] = strBytes[i];
        }
        return string(truncatedBytes);
    }
}
