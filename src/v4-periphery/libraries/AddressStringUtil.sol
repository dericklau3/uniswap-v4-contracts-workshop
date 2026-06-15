// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 地址字符串工具
/// @notice 将地址前若干十六进制字符转换为字符串，供 NFT 元数据展示。
/// @dev 参考：https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/AddressStringUtil.sol
library AddressStringUtil {
    error InvalidAddressLength(uint256 len);

    /// @notice 将地址转换为不带 `0x` 的大写十六进制字符串，并只提取指定字符数。
    /// @param addr 要转换的地址。
    /// @param len 输出字符数，必须为 2 的倍数且位于 1 到 40 之间。
    /// @return 十六进制字符串。
    function toAsciiString(address addr, uint256 len) internal pure returns (string memory) {
        if (!(len % 2 == 0 && len > 0 && len <= 40)) {
            revert InvalidAddressLength(len);
        }

        bytes memory s = new bytes(len);
        uint256 addrNum = uint256(uint160(addr));
        for (uint256 i = 0; i < len / 2; i++) {
            // 右移后截取最低字节，依次取得地址从高位开始的第 19-i 个字节。
            uint8 b = uint8(addrNum >> (8 * (19 - i)));
            // 第一个十六进制字符来自该字节高 4 位。
            uint8 hi = b >> 4;
            // 第二个十六进制字符来自该字节低 4 位。
            uint8 lo = b - (hi << 4);
            s[2 * i] = char(hi);
            s[2 * i + 1] = char(lo);
        }
        return string(s);
    }

    /// @notice 将 4 位数值转换为对应的大写十六进制 ASCII 字符。
    // hi 和 lo 都只占 4 位，取值范围为 0 到 15。
    /// @param b 要转换的半字节数值。
    /// @return c 对应 ASCII 字符。
    function char(uint8 b) private pure returns (bytes1 c) {
        if (b < 10) {
            return bytes1(b + 0x30);
        } else {
            return bytes1(b + 0x37);
        }
    }
}
