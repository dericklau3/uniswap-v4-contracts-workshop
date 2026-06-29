### Uniswap V4

#### Hooks

Hook 合约“有没有某个权限”，不是存在 PoolManager 的 storage 里，而是直接写进 Hook 合约地址的低 14 个 bit 里，节省 gas。

通过这样判断：uint160(hookAddress) & 某个权限flag != 0

以太坊地址本质上是一个 `160 bit` 的数字 uint160(address)

```
地址整体是 160 bit：

[ 高位很多 bit ........................................ 低 14 bit ]

Uniswap v4 只看最后这 14 个 bit 来判断 Hook 权限。
```

```
		// 初始化前后：常用于限制谁能建池、校验初始价格、记录池子元数据，或在建池后初始化外部业务状态。
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;

    // 加流动性前后：常用于白名单、激励记账、收取入池费用，或把一部分新增流动性收益分配给 Hook。
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;

    // 移除流动性前后：常用于退出限制、解锁期、赎回费用、收益结算或惩罚性扣款。
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;

    // 换币前后：是 Hook 最常用的业务入口，可实现动态手续费、限价单、TWAMM、路由保护和订单簿式扩展。
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;

    // 捐赠前后：donate 会把 token 捐给当前区间 LP，Hook 可用它做外部奖励、积分或协议激励分发的联动。
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;

    // return delta 权限：只有设置了这些位，Hook 返回的金额调整才会被 PoolManager 采纳。
    // 这相当于给 Hook “改账本”的授权；没有这些位时，即便 Hook 函数返回了额外数据，也只能当普通回调处理。
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;
```

| bit 位 | 十六进制 | 权限                                 |
| ------ | -------- | ------------------------------------ |
| bit 13 | `0x2000` | `beforeInitialize`                   |
| bit 12 | `0x1000` | `afterInitialize`                    |
| bit 11 | `0x0800` | `beforeAddLiquidity`                 |
| bit 10 | `0x0400` | `afterAddLiquidity`                  |
| bit 9  | `0x0200` | `beforeRemoveLiquidity`              |
| bit 8  | `0x0100` | `afterRemoveLiquidity`               |
| bit 7  | `0x0080` | `beforeSwap`                         |
| bit 6  | `0x0040` | `afterSwap`                          |
| bit 5  | `0x0020` | `beforeDonate`                       |
| bit 4  | `0x0010` | `afterDonate`                        |
| bit 3  | `0x0008` | `beforeSwap returns delta`           |
| bit 2  | `0x0004` | `afterSwap returns delta`            |
| bit 1  | `0x0002` | `afterAddLiquidity returns delta`    |
| bit 0  | `0x0001` | `afterRemoveLiquidity returns delta` |

```
ALL_HOOK_MASK = uint160((1 << 14) - 1) 或者 ALL_HOOK_MASK = 0x3fff  两者等同
# 二进制是：
11 1111 1111 1111
# 用它可以取出一个地址的低 14 位：
uint160(address(hook)) & ALL_HOOK_MASK

# 如果结果大于 0，说明这个地址至少开启了一个 Hook 权限。这个 hook 地址的低 14 位里面，至少有一个 bit 是 1。
也就是说，它至少声明启用了一个 Hook 回调。
uint160(address(hook)) & ALL_HOOK_MASK > 0
```

##### hasPermission

`hasPermission` 的逻辑本质上就是位运算

```
# 判断是否启用了 beforeSwap
self.hasPermission(BEFORE_SWAP_FLAG)
# 也就是检查地址低 14 位里的 bit 7 是否为 1。
uint160(address(self)) & (1 << 7) != 0
```

##### 例子

hooks地址：0x0000000000000000000000000000000000002400

```
# 只看低位
0x2400
# 拆开：
0x2400 = 0x2000 + 0x0400
# 对应权限是：
0x2000 = 1 << 13 = BEFORE_INITIALIZE_FLAG
0x0400 = 1 << 10 = AFTER_ADD_LIQUIDITY_FLAG
# 所以这个 Hook 地址表示：
启用了 beforeInitialize
启用了 afterAddLiquidity

# 0x2400 转换成 二进制观看
0x2400 = 0010 0100 0000 0000
# 只看低14位
10 0100 0000 0000

bit13 bit12 bit11 bit10 bit9 bit8 bit7 bit6 bit5 bit4 bit3 bit2 bit1 bit0
  1     0     0     1    0    0    0    0    0    0    0    0    0    0
  

bit13 = 1 -> beforeInitialize 开启
bit10 = 1 -> afterAddLiquidity 开启
其他 bit = 0 -> 其他 hook 不开启
```



#### BalanceDelta

在 Uniswap v4 里，很多操作不是马上转账，而是先记账。所以 `BalanceDelta` 就是在描述：

```
这次操作之后：
- token0 谁欠谁多少？
- token1 谁欠谁多少？

把两个 int128 打包进一个 int256
BalanceDelta = [ amount0 | amount1 ]
                128 bits   128 bits

# swap
amount0 = -1 ETH
amount1 = +3000 USDC
ETH 方向：你欠 PoolManager 1 ETH
USDC 方向：PoolManager 欠你 3000 USDC

# add liquidity
amount0 = -1 ETH
amount1 = -3000 USDC
你欠 PoolManager 1 ETH
你欠 PoolManager 3000 USDC

# remove liquidity
amount0 = +1 ETH
amount1 = +3000 USDC
PoolManager 欠你 1 ETH
PoolManager 欠你 3000 USDC
```



#### swapExactInSingle

```
bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

bytes memory actions = abi.encodePacked(
    uint8(Actions.SWAP_EXACT_IN_SINGLE),
    uint8(Actions.SETTLE_ALL),
    uint8(Actions.TAKE_ALL)
);

bytes[] memory params = new bytes[](3);

params[0] = abi.encode(
    IV4Router.ExactInputSingleParams({
        poolKey: key,
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: minAmountOut,
        minHopPriceX36: 0,
        hookData: bytes("")
    })
);

// 支付输入币
params[1] = abi.encode(key.currency0, amountIn);

// 拿走输出币
params[2] = abi.encode(key.currency1, minAmountOut);

bytes[] memory inputs = new bytes[](1);
inputs[0] = abi.encode(actions, params);

router.execute(commands, inputs, deadline);
```



#### swapExactIn

```
ETH -> USDT -> BTC

bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

bytes memory actions = abi.encodePacked(
    uint8(Actions.SWAP_EXACT_IN),
    uint8(Actions.SETTLE_ALL),
    uint8(Actions.TAKE_ALL)
);

bytes[] memory params = new bytes[](3);

currencyA = ETH
PathKey[] path = new PathKey[](2);
path[0] = PathKey(Currency.wrap(USDT), 3000, 60, IHooks(address(0)), bytes(""));
path[1] = PathKey(Currency.wrap(BTC), 3000, 60, IHooks(address(0)), bytes(""));

params[0] = abi.encode(
    IV4Router.ExactInputParams({
        currencyIn: currencyA,
        path: path,
        minHopPriceX36: new uint256[](0),
        amountIn: amountIn,
        amountOutMinimum: minAmountOut
    })
);

// 支付最初输入币 ETH
params[1] = abi.encode(ETH, amountIn);

// 拿最终输出币  BTC
params[2] = abi.encode(BTC, minAmountOut);

bytes[] memory inputs = new bytes[](1);
inputs[0] = abi.encode(actions, params);

router.execute(commands, inputs, deadline);
```



#### swapExactOutSingle

```
bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

bytes memory actions = abi.encodePacked(
    uint8(Actions.SWAP_EXACT_OUT_SINGLE),
    uint8(Actions.SETTLE_ALL),
    uint8(Actions.TAKE_ALL)
);

bytes[] memory params = new bytes[](3);

params[0] = abi.encode(
    IV4Router.ExactOutputSingleParams({
        poolKey: key,
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: amountInMax,
        minHopPriceX36: 0,
        hookData: bytes("")
    })
);

// 最多支付 token0 的 amountInMax
params[1] = abi.encode(key.currency0, amountInMax);

// 拿走精确输出 token1
params[2] = abi.encode(key.currency1, amountOut);

bytes[] memory inputs = new bytes[](1);
inputs[0] = abi.encode(actions, params);

router.execute(commands, inputs, deadline);
```



#### swapExactOut

```
ETH -> USDT -> BTC
A = ETH
B = USDT
C = BTC

bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

bytes memory actions = abi.encodePacked(
    uint8(Actions.SWAP_EXACT_OUT),
    uint8(Actions.SETTLE_ALL),
    uint8(Actions.TAKE_ALL)
);

bytes[] memory params = new bytes[](3);

PathKey[] path = new PathKey[](2);
path[0] = PathKey(Currency.wrap(ETH), 3000, 60, IHooks(address(0)), bytes(""));
path[1] = PathKey(Currency.wrap(USDT), 3000, 60, IHooks(address(0)), bytes(""));

params[0] = abi.encode(
    IV4Router.ExactOutputParams({
        currencyOut: currencyC,
        path: path,
        minHopPriceX36: new uint256[](0),
        amountOut: amountOut,
        amountInMaximum: amountInMax
    })
);

// 最多支付最初输入币 A
params[1] = abi.encode(currencyA, amountInMax);

// 拿最终输出币 C
params[2] = abi.encode(currencyC, amountOut);

bytes[] memory inputs = new bytes[](1);
inputs[0] = abi.encode(actions, params);

router.execute(commands, inputs, deadline);
```

