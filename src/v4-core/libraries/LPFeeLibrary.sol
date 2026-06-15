// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CustomRevert} from "./CustomRevert.sol";

/// @notice 处理池 LP 费率、动态费率标志与单次兑换覆盖费率的工具库。
library LPFeeLibrary {
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    /// @notice 池的静态费率或 hook 返回的动态费率超过 100% 时抛出。
    error LPFeeTooLarge(uint24 fee);

    /// @notice LP fee 严格等于 0b1000000... 时表示动态费率池；该值大于 MAX_LP_FEE，不能作为静态费率。
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @notice beforeSwap 返回费率的第二高 bit，表示本次兑换是否覆盖池中存储的 LP fee。
    // 只有动态费率池才能通过 beforeSwap hook 返回并使用覆盖费率。
    uint24 public constant OVERRIDE_FEE_FLAG = 0x400000;

    /// @notice 从 beforeSwap hook 返回费率中移除 override flag 的掩码。
    uint24 public constant REMOVE_OVERRIDE_MASK = 0xBFFFFF;

    /// @notice LP fee 以百分之一 bip 表示，因此 1_000_000 对应 100%。
    uint24 public constant MAX_LP_FEE = 1000000;

    /// @notice 判断池的 LP fee 是否为动态费率标志。
    /// @param self 要检查的费率。
    /// @return bool 若为动态费率标志则返回 true。
    function isDynamicFee(uint24 self) internal pure returns (bool) {
        return self == DYNAMIC_FEE_FLAG;
    }

    /// @notice 判断 LP fee 是否有效，即是否不高于允许的最大费率。
    /// @param self 要检查的费率。
    /// @return bool 费率有效时返回 true。
    function isValid(uint24 self) internal pure returns (bool) {
        return self <= MAX_LP_FEE;
    }

    /// @notice 验证 LP fee 是否超过上限，无效时回滚。
    /// @param self 要验证的费率。
    function validate(uint24 self) internal pure {
        if (!self.isValid()) LPFeeTooLarge.selector.revertWith(self);
    }

    /// @notice 获取并验证池的初始 LP fee；动态费率池初始化时费率为 0。
    /// @dev 动态费率池若希望初始费率非 0，应在 afterInitialize hook 中调用 `updateDynamicLPFee`。
    /// @param self 用于取得初始 LP fee 的配置值。
    /// @return initialFee 动态费率配置返回 0，否则返回通过验证的静态费率。
    function getInitialLPFee(uint24 self) internal pure returns (uint24) {
        // 动态费率池的初始费率固定为 0。
        if (self.isDynamicFee()) return 0;
        self.validate();
        return self;
    }

    /// @notice 判断费率是否设置 override flag（uint24 的第二高 bit）。
    /// @param self 要检查的费率。
    /// @return bool 设置了 override flag 时返回 true。
    function isOverride(uint24 self) internal pure returns (bool) {
        return self & OVERRIDE_FEE_FLAG != 0;
    }

    /// @notice 返回移除 override flag 后的纯费率值。
    /// @param self 要移除 override flag 的费率。
    /// @return fee 未设置 override flag 的费率。
    function removeOverrideFlag(uint24 self) internal pure returns (uint24) {
        return self & REMOVE_OVERRIDE_MASK;
    }

    /// @notice 移除 override flag 并验证费率；费率过大时回滚。
    /// @param self 要移除标志并验证的费率。
    /// @return fee 移除 override flag 后的有效费率。
    function removeOverrideFlagAndValidate(uint24 self) internal pure returns (uint24 fee) {
        fee = self.removeOverrideFlag();
        fee.validate();
    }
}
