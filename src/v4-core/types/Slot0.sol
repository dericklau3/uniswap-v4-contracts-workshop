// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Slot0 是将多个池核心字段压缩进一个 bytes32 的结构。
 * 使用打包形式可避免把各字段分别存入内存/存储槽，从而节省 gas。
 *
 * 布局：
 * 24 bits 空位 | 24 bits lpFee | 12 bits protocolFee 1->0 | 12 bits protocolFee 0->1 | 24 bits tick | 160 bits sqrtPriceX96
 *
 * 从最低有效位开始，各字段依次为：
 *
 * 当前价格
 * uint160 sqrtPriceX96;
 *
 * 当前 tick
 * int24 tick;
 *
 * 协议费以百分之一 bip 表示；高 12 bit 对应 1->0，低 12 bit 对应 0->1。
 * 最大值为 1000，即协议费最高为 0.1%。
 * 计费顺序是先从输入中扣协议费，再对剩余输入收取 lpFee。
 * uint24 protocolFee;
 *
 * 池当前的 LP 费率；若池使用动态费率，这里不包含 dynamic fee flag。
 * uint24 lpFee;
 */
type Slot0 is bytes32;

using Slot0Library for Slot0 global;

/// @notice 读取和更新 Slot0 各打包字段的工具库。
library Slot0Library {
    uint160 internal constant MASK_160_BITS = 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;

    uint8 internal constant TICK_OFFSET = 160;
    uint8 internal constant PROTOCOL_FEE_OFFSET = 184;
    uint8 internal constant LP_FEE_OFFSET = 208;

    // #### 读取器 ####
    function sqrtPriceX96(Slot0 _packed) internal pure returns (uint160 _sqrtPriceX96) {
        assembly ("memory-safe") {
            _sqrtPriceX96 := and(MASK_160_BITS, _packed)
        }
    }

    function tick(Slot0 _packed) internal pure returns (int24 _tick) {
        assembly ("memory-safe") {
            _tick := signextend(2, shr(TICK_OFFSET, _packed))
        }
    }

    function protocolFee(Slot0 _packed) internal pure returns (uint24 _protocolFee) {
        assembly ("memory-safe") {
            _protocolFee := and(MASK_24_BITS, shr(PROTOCOL_FEE_OFFSET, _packed))
        }
    }

    function lpFee(Slot0 _packed) internal pure returns (uint24 _lpFee) {
        assembly ("memory-safe") {
            _lpFee := and(MASK_24_BITS, shr(LP_FEE_OFFSET, _packed))
        }
    }

    // #### 写入器 ####
    function setSqrtPriceX96(Slot0 _packed, uint160 _sqrtPriceX96) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result := or(and(not(MASK_160_BITS), _packed), and(MASK_160_BITS, _sqrtPriceX96))
        }
    }

    function setTick(Slot0 _packed, int24 _tick) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result := or(and(not(shl(TICK_OFFSET, MASK_24_BITS)), _packed), shl(TICK_OFFSET, and(MASK_24_BITS, _tick)))
        }
    }

    function setProtocolFee(Slot0 _packed, uint24 _protocolFee) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result :=
                or(
                    and(not(shl(PROTOCOL_FEE_OFFSET, MASK_24_BITS)), _packed),
                    shl(PROTOCOL_FEE_OFFSET, and(MASK_24_BITS, _protocolFee))
                )
        }
    }

    function setLpFee(Slot0 _packed, uint24 _lpFee) internal pure returns (Slot0 _result) {
        assembly ("memory-safe") {
            _result :=
                or(and(not(shl(LP_FEE_OFFSET, MASK_24_BITS)), _packed), shl(LP_FEE_OFFSET, and(MASK_24_BITS, _lpFee)))
        }
    }
}
