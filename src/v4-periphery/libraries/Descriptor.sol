// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {SVG} from "./SVG.sol";
import {HexStrings} from "./HexStrings.sol";

/// @title 仓位描述器
/// @notice 把 V4 仓位的池、费率、价格区间和当前状态编码为 ERC-721 JSON 元数据及 SVG 图像。
/// @dev 参考：https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/NFTDescriptor.sol
library Descriptor {
    using TickMath for int24;
    using Strings for uint256;
    using HexStrings for uint256;
    using LPFeeLibrary for uint24;

    uint256 constant sqrt10X128 = 1076067327063303206878105757264492625226;

    struct ConstructTokenURIParams {
        uint256 tokenId;
        address quoteCurrency;
        address baseCurrency;
        string quoteCurrencySymbol;
        string baseCurrencySymbol;
        uint8 quoteCurrencyDecimals;
        uint8 baseCurrencyDecimals;
        bool flipRatio;
        int24 tickLower;
        int24 tickUpper;
        int24 tickCurrent;
        int24 tickSpacing;
        uint24 fee;
        address poolManager;
        address hooks;
    }

    /// @notice 构造 Uniswap V4 仓位 NFT 的完整 token URI。
    /// @param params 生成名称、描述和 SVG 所需的池与仓位参数。
    /// @return Base64 编码 JSON 的 data URI 字符串。
    function constructTokenURI(ConstructTokenURIParams memory params) internal pure returns (string memory) {
        string memory name = generateName(params, feeToPercentString(params.fee));
        string memory descriptionPartOne = generateDescriptionPartOne(
            escapeSpecialCharacters(params.quoteCurrencySymbol),
            escapeSpecialCharacters(params.baseCurrencySymbol),
            addressToString(params.poolManager)
        );
        string memory descriptionPartTwo = generateDescriptionPartTwo(
            params.tokenId.toString(),
            escapeSpecialCharacters(params.baseCurrencySymbol),
            params.quoteCurrency == address(0) ? "Native" : addressToString(params.quoteCurrency),
            params.baseCurrency == address(0) ? "Native" : addressToString(params.baseCurrency),
            params.hooks == address(0) ? "No Hook" : addressToString(params.hooks),
            feeToPercentString(params.fee)
        );
        string memory image = Base64.encode(bytes(generateSVGImage(params)));

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            name,
                            '", "description":"',
                            descriptionPartOne,
                            descriptionPartTwo,
                            '", "image": "',
                            "data:image/svg+xml;base64,",
                            image,
                            '"}'
                        )
                    )
                )
            )
        );
    }

    /// @notice 对字符串中的 JSON 特殊控制字符添加反斜杠转义。
    function escapeSpecialCharacters(string memory symbol) internal pure returns (string memory) {
        bytes memory symbolBytes = bytes(symbol);
        uint8 specialCharCount = 0;
        // 统计双引号、换页、换行、回车和制表符数量，以预分配转义后的数组。
        for (uint8 i = 0; i < symbolBytes.length; i++) {
            if (isSpecialCharacter(symbolBytes[i])) {
                specialCharCount++;
            }
        }
        if (specialCharCount > 0) {
            // 新数组长度为原字符串加每个特殊字符前所需的反斜杠。
            bytes memory escapedBytes = new bytes(symbolBytes.length + specialCharCount);
            uint256 index;
            for (uint8 i = 0; i < symbolBytes.length; i++) {
                // 在双引号及各类控制字符前插入 '\'。
                if (isSpecialCharacter(symbolBytes[i])) {
                    escapedBytes[index++] = "\\";
                }
                // 把原字符复制到新数组。
                escapedBytes[index++] = symbolBytes[i];
            }
            return string(escapedBytes);
        }
        return symbol;
    }

    /// @notice 生成 Uniswap V4 仓位 NFT 描述文本的第一部分。
    /// @param quoteCurrencySymbol 报价货币符号。
    /// @param baseCurrencySymbol 基础货币符号。
    /// @param poolManager PoolManager 地址。
    /// @return 描述第一部分。
    function generateDescriptionPartOne(
        string memory quoteCurrencySymbol,
        string memory baseCurrencySymbol,
        string memory poolManager
    ) private pure returns (string memory) {
        // 展示顺序先 quote 后 base，与价格 quote/base 的阅读顺序一致。
        return string(
            abi.encodePacked(
                "This NFT represents a liquidity position in a Uniswap v4 ",
                quoteCurrencySymbol,
                "-",
                baseCurrencySymbol,
                " pool. ",
                "The owner of this NFT can modify or redeem the position.\\n",
                "\\nPool Manager Address: ",
                poolManager,
                "\\n",
                quoteCurrencySymbol
            )
        );
    }

    /// @notice 生成仓位 NFT 描述文本的第二部分，补充 token、货币、hook 与费率信息。
    /// @param tokenId NFT token ID。
    /// @param baseCurrencySymbol 基础货币符号。
    /// @param quoteCurrency 报价货币地址。
    /// @param baseCurrency 基础货币地址。
    /// @param hooks hook 合约地址。
    /// @param feeTier 池费率。
    /// @return 描述第二部分。
    function generateDescriptionPartTwo(
        string memory tokenId,
        string memory baseCurrencySymbol,
        string memory quoteCurrency,
        string memory baseCurrency,
        string memory hooks,
        string memory feeTier
    ) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                " Address: ",
                quoteCurrency,
                "\\n",
                baseCurrencySymbol,
                " Address: ",
                baseCurrency,
                "\\nHook Address: ",
                hooks,
                "\\nFee Tier: ",
                feeTier,
                "\\nToken ID: ",
                tokenId,
                "\\n\\n",
                unicode"⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure currency addresses match the expected currencies, as currency symbols may be imitated."
            )
        );
    }

    /// @notice 生成包含交易对、费率和价格区间的仓位 NFT 名称。
    /// @param params 生成名称所需的仓位参数。
    /// @param feeTier 池费率的百分比字符串。
    /// @return NFT 名称。
    function generateName(ConstructTokenURIParams memory params, string memory feeTier)
        private
        pure
        returns (string memory)
    {
        // 图像中的价格统一按 quoteCurrency/baseCurrency 表示。
        return string(
            abi.encodePacked(
                "Uniswap - ",
                feeTier,
                " - ",
                escapeSpecialCharacters(params.quoteCurrencySymbol),
                "/",
                escapeSpecialCharacters(params.baseCurrencySymbol),
                " - ",
                tickToDecimalString(
                    !params.flipRatio ? params.tickLower : params.tickUpper,
                    params.tickSpacing,
                    params.baseCurrencyDecimals,
                    params.quoteCurrencyDecimals,
                    params.flipRatio
                ),
                "<>",
                tickToDecimalString(
                    !params.flipRatio ? params.tickUpper : params.tickLower,
                    params.tickSpacing,
                    params.baseCurrencyDecimals,
                    params.quoteCurrencyDecimals,
                    params.flipRatio
                )
            )
        );
    }

    struct DecimalStringParams {
        // 十进制字符串要保留的有效数字。
        uint256 sigfigs;
        // 最终十进制字符串长度。
        uint8 bufferLength;
        // 有效数字结束索引；复制有效数字时会从后向前处理。
        uint8 sigfigIndex;
        // 小数点位置；0 表示不包含小数点。
        uint8 decimalIndex;
        // 极小或极大数字需要补前导/尾随 0 的起始索引。
        uint8 zerosStartIndex;
        // 补前导/尾随 0 的结束索引。
        uint8 zerosEndIndex;
        // 十进制数是否小于 1。
        bool isLessThanOne;
        // 输出字符串是否附带 "%"。
        bool isPercent;
    }

    function generateDecimalString(DecimalStringParams memory params) private pure returns (string memory) {
        bytes memory buffer = new bytes(params.bufferLength);
        if (params.isPercent) {
            buffer[buffer.length - 1] = "%";
        }
        if (params.isLessThanOne) {
            buffer[0] = "0";
            buffer[1] = ".";
        }

        // 写入前导或尾随 0。
        for (uint256 zerosCursor = params.zerosStartIndex; zerosCursor < params.zerosEndIndex + 1; zerosCursor++) {
            // 把数字 0 的 ASCII 码 48 转为 bytes1 写入缓冲区。
            buffer[zerosCursor] = bytes1(uint8(48));
        }
        // 写入有效数字。
        while (params.sigfigs > 0) {
            if (params.decimalIndex > 0 && params.sigfigIndex == params.decimalIndex) {
                buffer[params.sigfigIndex--] = ".";
            }
            buffer[params.sigfigIndex] = bytes1(uint8(48 + (params.sigfigs % 10)));
            // sigfigIndex 为 0 时递减会下溢，因此在 unchecked 中依赖循环边界退出。
            unchecked {
                params.sigfigIndex--;
            }
            params.sigfigs /= 10;
        }
        return string(buffer);
    }

    /// @notice 将指定 tick 对应的 quote/base 价格转换为十进制字符串。
    /// @dev tick 位于价格曲线底部或顶部边界时返回 `MIN` 或 `MAX`。
    /// @param tick tickLower 或 tickUpper。
    /// @param tickSpacing 池 tick 间距。
    /// @param baseCurrencyDecimals 基础货币小数位。
    /// @param quoteCurrencyDecimals 报价货币小数位。
    /// @param flipRatio 是否翻转默认 currency1/currency0 比率。
    /// @return 价格比率字符串。
    function tickToDecimalString(
        int24 tick,
        int24 tickSpacing,
        uint8 baseCurrencyDecimals,
        uint8 quoteCurrencyDecimals,
        bool flipRatio
    ) internal pure returns (string memory) {
        if (tick == (TickMath.MIN_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? "MIN" : "MAX";
        } else if (tick == (TickMath.MAX_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? "MAX" : "MIN";
        } else {
            uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
            if (flipRatio) {
                sqrtRatioX96 = uint160(uint256(1 << 192) / sqrtRatioX96);
            }
            return fixedPointToDecimalString(sqrtRatioX96, baseCurrencyDecimals, quoteCurrencyDecimals);
        }
    }

    function sigfigsRounded(uint256 value, uint8 digits) private pure returns (uint256, bool) {
        bool extraDigit;
        if (digits > 5) {
            value = value / (10 ** (digits - 5));
        }
        bool roundUp = value % 10 > 4;
        value = value / 10;
        if (roundUp) {
            value = value + 1;
        }
        // 99999 舍入到 100000 时会多出一位有效数字，需要单独调整。
        if (value == 100000) {
            value /= 10;
            extraDigit = true;
        }
        return (value, extraDigit);
    }

    /// @notice 根据基础货币与报价货币的小数位差调整平方根价格。
    /// @param sqrtRatioX96 指定 tick 的平方根价格。
    /// @param baseCurrencyDecimals 基础货币小数位。
    /// @param quoteCurrencyDecimals 报价货币小数位。
    /// @return adjustedSqrtRatioX96 完成十进制尺度调整后的平方根价格。
    function adjustForDecimalPrecision(uint160 sqrtRatioX96, uint8 baseCurrencyDecimals, uint8 quoteCurrencyDecimals)
        private
        pure
        returns (uint256 adjustedSqrtRatioX96)
    {
        uint256 difference = abs(int256(uint256(baseCurrencyDecimals)) - (int256(uint256(quoteCurrencyDecimals))));
        if (difference > 0 && difference <= 18) {
            if (baseCurrencyDecimals > quoteCurrencyDecimals) {
                adjustedSqrtRatioX96 = sqrtRatioX96 * (10 ** (difference / 2));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, sqrt10X128, 1 << 128);
                }
            } else {
                adjustedSqrtRatioX96 = sqrtRatioX96 / (10 ** (difference / 2));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, 1 << 128, sqrt10X128);
                }
            }
        } else {
            adjustedSqrtRatioX96 = uint256(sqrtRatioX96);
        }
    }

    /// @notice 返回有符号整数绝对值。
    /// @param x 输入有符号整数。
    /// @return x 的绝对值。
    function abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function fixedPointToDecimalString(uint160 sqrtRatioX96, uint8 baseCurrencyDecimals, uint8 quoteCurrencyDecimals)
        internal
        pure
        returns (string memory)
    {
        uint256 adjustedSqrtRatioX96 =
            adjustForDecimalPrecision(sqrtRatioX96, baseCurrencyDecimals, quoteCurrencyDecimals);
        uint256 value = FullMath.mulDiv(adjustedSqrtRatioX96, adjustedSqrtRatioX96, 1 << 64);

        bool priceBelow1 = adjustedSqrtRatioX96 < 2 ** 96;
        if (priceBelow1) {
            // 10 ** 43 提供读取最小可能价格 5 位有效数字所需精度，并额外保留 1 位用于舍入。
            value = FullMath.mulDiv(value, 10 ** 44, 1 << 128);
        } else {
            // 保留 4 位小数精度，并额外留 1 位用于舍入。
            value = FullMath.mulDiv(value, 10 ** 5, 1 << 128);
        }

        // 计算整数数字位数。
        uint256 temp = value;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        // 不把为舍入额外保留的那一位计入结果。
        digits = digits - 1;

        // 根据额外保留位执行四舍五入。
        (uint256 sigfigs, bool extraDigit) = sigfigsRounded(value, digits);
        if (extraDigit) {
            digits++;
        }

        DecimalStringParams memory params;
        if (priceBelow1) {
            // 7 字节（"0." 加 5 位有效数字）再加小数点后的前导零。
            params.bufferLength = uint8(uint8(7) + (uint8(43) - digits));
            params.zerosStartIndex = 2;
            params.zerosEndIndex = uint8(uint256(43) - digits + 1);
            params.sigfigIndex = uint8(params.bufferLength - 1);
        } else if (digits >= 9) {
            // 价格字符串不需要小数点。
            params.bufferLength = uint8(digits - 4);
            params.zerosStartIndex = 5;
            params.zerosEndIndex = uint8(params.bufferLength - 1);
            params.sigfigIndex = 4;
        } else {
            // 5 位有效数字分布在小数点两侧。
            params.bufferLength = 6;
            params.sigfigIndex = 5;
            params.decimalIndex = uint8(digits - 5 + 1);
        }
        params.sigfigs = sigfigs;
        params.isLessThanOne = priceBelow1;
        params.isPercent = false;

        return generateDecimalString(params);
    }

    /// @notice 将以 pips 表示的费率转换为带百分号的十进制字符串。
    /// @param fee 费率数值。
    /// @return 带百分号的费率字符串。
    function feeToPercentString(uint24 fee) internal pure returns (string memory) {
        if (fee.isDynamicFee()) {
            return "Dynamic";
        }
        if (fee == 0) {
            return "0%";
        }
        uint24 temp = fee;
        uint256 digits;
        uint8 numSigfigs;
        // 反复除以 10 遍历费率各位，计算总位数和有效数字位数。
        while (temp != 0) {
            if (numSigfigs > 0) {
                // 从最低非零有效位开始统计其前面的全部数字。
                numSigfigs++;
            } else if (temp % 10 != 0) {
                numSigfigs++;
            }
            digits++;
            temp /= 10;
        }

        DecimalStringParams memory params;
        uint256 nZeros;
        if (digits >= 5) {
            // 表示费率大于或等于 1%；第 5 位是个位。
            uint256 decimalPlace = digits - numSigfigs >= 4 ? 0 : 1;
            nZeros = digits - 5 < numSigfigs - 1 ? 0 : digits - 5 - (numSigfigs - 1);
            params.zerosStartIndex = numSigfigs;
            params.zerosEndIndex = uint8(params.zerosStartIndex + nZeros - 1);
            params.sigfigIndex = uint8(params.zerosStartIndex - 1 + decimalPlace);
            params.bufferLength = uint8(nZeros + numSigfigs + 1 + decimalPlace);
        } else {
            // 表示费率小于 1%。
            nZeros = 5 - digits; // number of zeros, inlcuding the zero before decimal
            params.zerosStartIndex = 2; // leading zeros will start after the decimal point
            params.zerosEndIndex = uint8(nZeros + params.zerosStartIndex - 1); // end index for leading zeros
            params.bufferLength = uint8(nZeros + numSigfigs + 2); // total length of string buffer, including "0." and "%"
            params.sigfigIndex = uint8(params.bufferLength - 2); // index of starting signficant figure
            params.isLessThanOne = true;
        }
        params.sigfigs = uint256(fee) / (10 ** (digits - numSigfigs)); // the signficant figures of the fee
        params.isPercent = true;
        params.decimalIndex = digits > 4 ? uint8(digits - 4) : 0; // based on total number of digits in the fee

        return generateDecimalString(params);
    }

    function addressToString(address addr) internal pure returns (string memory) {
        return (uint256(uint160(addr))).toHexString(20);
    }

    /// @notice 生成 Uniswap V4 仓位 NFT 的 SVG 图像。
    /// @param params 生成图像所需的仓位和池参数。
    /// @return svg SVG 字符串。
    function generateSVGImage(ConstructTokenURIParams memory params) internal pure returns (string memory svg) {
        SVG.SVGParams memory svgParams = SVG.SVGParams({
            quoteCurrency: addressToString(params.quoteCurrency),
            baseCurrency: addressToString(params.baseCurrency),
            hooks: params.hooks,
            quoteCurrencySymbol: params.quoteCurrencySymbol,
            baseCurrencySymbol: params.baseCurrencySymbol,
            feeTier: feeToPercentString(params.fee),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            tickSpacing: params.tickSpacing,
            overRange: overRange(params.tickLower, params.tickUpper, params.tickCurrent),
            tokenId: params.tokenId,
            color0: currencyToColorHex(uint256(uint160(params.quoteCurrency)), 136),
            color1: currencyToColorHex(uint256(uint160(params.baseCurrency)), 136),
            color2: currencyToColorHex(uint256(uint160(params.quoteCurrency)), 0),
            color3: currencyToColorHex(uint256(uint160(params.baseCurrency)), 0),
            x1: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 16, params.tokenId), 0, 255, 16, 274),
            y1: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 16, params.tokenId), 0, 255, 100, 484),
            x2: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 32, params.tokenId), 0, 255, 16, 274),
            y2: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 32, params.tokenId), 0, 255, 100, 484),
            x3: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 48, params.tokenId), 0, 255, 16, 274),
            y3: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 48, params.tokenId), 0, 255, 100, 484)
        });

        return SVG.generateSVG(svgParams);
    }

    /// @notice 判断当前价格位于仓位区间内、区间上方还是区间下方。
    /// @param tickLower 仓位下界 tick。
    /// @param tickUpper 仓位上界 tick。
    /// @param tickCurrent 当前 tick。
    /// @return 区间内返回 0，低于区间返回 -1，高于区间返回 1。
    function overRange(int24 tickLower, int24 tickUpper, int24 tickCurrent) private pure returns (int8) {
        if (tickCurrent < tickLower) {
            return -1;
        } else if (tickCurrent > tickUpper) {
            return 1;
        } else {
            return 0;
        }
    }

    function isSpecialCharacter(bytes1 b) private pure returns (bool) {
        return b == '"' || b == "\u000c" || b == "\n" || b == "\r" || b == "\t";
    }

    function scale(uint256 n, uint256 inMn, uint256 inMx, uint256 outMn, uint256 outMx)
        private
        pure
        returns (string memory)
    {
        return ((n - inMn) * (outMx - outMn) / (inMx - inMn) + outMn).toString();
    }

    function currencyToColorHex(uint256 currency, uint256 offset) internal pure returns (string memory str) {
        return string((currency >> offset).toHexStringNoPrefix(3));
    }

    function getCircleCoord(uint256 currency, uint256 offset, uint256 tokenId) internal pure returns (uint256) {
        return (sliceCurrencyHex(currency, offset) * tokenId) % 255;
    }

    function sliceCurrencyHex(uint256 currency, uint256 offset) internal pure returns (uint256) {
        return uint256(uint8(currency >> offset));
    }
}
