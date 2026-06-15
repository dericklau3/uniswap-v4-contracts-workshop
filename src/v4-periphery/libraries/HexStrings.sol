// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 十六进制字符串工具
/// @notice 将无符号整数转换为固定长度十六进制字符串。
/// @dev 参考：https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/HexStrings.sol
library HexStrings {
    bytes16 internal constant ALPHABET = "0123456789abcdef";

    /// @notice 将数字转换为固定字节长度、且不带 `0x` 前缀的十六进制字符串。
    /// @param value 要转换的数字。
    /// @param length 输出采用的字节数；从数值最低位向前保留。
    /// @return 十六进制字符串。
    function toHexStringNoPrefix(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length);
        for (uint256 i = buffer.length; i > 0; i--) {
            buffer[i - 1] = ALPHABET[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }
}
