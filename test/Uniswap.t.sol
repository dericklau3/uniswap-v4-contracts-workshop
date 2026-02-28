// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "@uniswap/permit2/src/interfaces/IPermit2.sol";

import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import "@uniswap/v4-periphery/src/libraries/Actions.sol";
import "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import "@uniswap/universal-router/contracts/libraries/Commands.sol";

import "./HookFactory.sol";
import "./SwapHook.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1000_000_000e18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract UniswapTest is Test {
    uint256 accountPrivateKey;
    address account;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    bytes32 public constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(PermitDetails[] details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    bytes32 public constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

    MockERC20 usdt;
    MockERC20 weth;
    MockERC20 btc;

    IPermit2 public permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    IPoolManager poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager positionManager = IPositionManager(payable(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e));
    
    IUniversalRouter universalRouter = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    V4Quoter v4Quoter = V4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);

    function setUp() public {
        vm.createSelectFork("mainnet", 24532300);

        (account, accountPrivateKey) = makeAddrAndKey("account");

        vm.startBroadcast(account);
        usdt = new MockERC20();
        weth = new MockERC20();
        btc = new MockERC20();
        vm.stopBroadcast();

        vm.label(address(usdt), "USDT");
        vm.label(address(weth), "WETH");
        vm.label(address(btc), "WBTC");
    }

    function testAddLiquidity() public {
        vm.startBroadcast(account);
        _addLiquidityV4(address(weth), address(usdt), 10e18, 30000e18);
        vm.stopBroadcast();
    }

    function testSwap() public {
        vm.startBroadcast(account);
        _addLiquidityV4(address(weth), address(usdt), 10e18, 30000e18);

        usdt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdt), address(universalRouter), type(uint160).max, type(uint48).max);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        (address token0, address token1) = address(weth) < address(usdt) ? (address(weth), address(usdt)) : (address(usdt), address(weth));
        bool zeroForOne = token0 == address(weth);
        console.log("token0 == weth: ", zeroForOne);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: !zeroForOne,
                amountIn: 1000e18,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            })
        );
        if (zeroForOne) {
            params[1] = abi.encode(key.currency1, 1000e18);
            params[2] = abi.encode(key.currency0, 0);
        } else {
            params[1] = abi.encode(key.currency0, 1000e18);
            params[2] = abi.encode(key.currency1, 0);
        }

        inputs[0] = abi.encode(actions, params);

        uint256 balBefore = usdt.balanceOf(account);
        universalRouter.execute(commands, inputs, block.timestamp + 30 minutes);
        uint256 balAfter = usdt.balanceOf(account);
        console.log("balBefore: ", balBefore);
        console.log("balAfter: ", balAfter);
        console.log("diff: ", balBefore - balAfter);
        vm.stopBroadcast();
    }

    function _addLiquidityV4(address tokenA, address tokenB, uint256 tokenAAmount, uint256 tokenBAmount) internal {
        // ETH 用 0x0000000000000000000000000000000000000000表示
        ERC20(tokenA).approve(address(permit2), type(uint256).max);
        ERC20(tokenB).approve(address(permit2), type(uint256).max);

        permit2.approve(tokenA, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(tokenB, address(positionManager), type(uint160).max, type(uint48).max);


        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (uint256 amount0, uint256 amount1) = tokenA < tokenB ? (tokenAAmount, tokenBAmount) : (tokenBAmount, tokenAAmount);

        uint160 sqrtPriceX96 = calculateSqrtPriceX96(tokenA, tokenB, tokenAAmount, tokenBAmount);
        console.log("sqrtPriceX96: ", uint256(sqrtPriceX96));

        // wrap: Currency c = Currency.wrap(tokenAddress);
        // unwrap: address a = Currency.unwrap(c);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        positionManager.initializePool(poolKey, sqrtPriceX96);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](2);

        (int24 tickLower, int24 tickUpper) = calculateAMMRange(address(weth), address(usdt), 0, 0, 0, 0, 60);
        console.log("tickLower: ", tickLower);
        console.log("tickUpper: ", tickUpper);

        uint128 liquidity = getLiquidityForAmounts(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        console.log("liquidity: ", liquidity);

        // PoolKey calldata poolKey,
        // int24 tickLower,
        // int24 tickUpper,
        // uint256 liquidity,
        // uint128 amount0Max,
        // uint128 amount1Max,
        // address owner,
        // bytes calldata hookData
        mintParams[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity - 10000, uint128(amount0), uint128(amount1), account, new bytes(0));
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, mintParams), block.timestamp + 30 minutes);
    }

    function testCreateHook() public {
        vm.startBroadcast(account);
        _createSwapHook();
        vm.stopBroadcast();
    }

    function _createSwapHook() internal returns (address) {
        // 部署工厂合约
        HookFactory factory = new HookFactory();
        // 设置hook权限
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        // 准备创建代码和构造函数参数
        bytes memory creationCode = type(SwapHook).creationCode;
        bytes memory constructorArgs = abi.encode(address(poolManager));

        // 查找合适的salt并部署hook
        (address hookAddress, bytes32 salt) = factory.find(permissions, creationCode, constructorArgs);
        factory.deployHook(hookAddress, salt, creationCode, constructorArgs);

        return hookAddress;
    }

    function testAddLiquidityV4WithHooks() public {
        vm.startBroadcast(account);
        address hookAddress = _createSwapHook();
        _addLiquidityV4WithHooks(address(weth), address(usdt), 10e18, 30000e18, hookAddress);
        vm.stopBroadcast();
    }

    function testSwapWithHooks() public {
        vm.startBroadcast(account);

         address hookAddress = _createSwapHook();

        _addLiquidityV4WithHooks(address(weth), address(usdt), 10e18, 30000e18, hookAddress);

        usdt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdt), address(universalRouter), type(uint160).max, type(uint48).max);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        (address token0, address token1) = address(weth) < address(usdt) ? (address(weth), address(usdt)) : (address(usdt), address(weth));
        bool zeroForOne = token0 == address(weth);
        console.log("token0 == weth: ", zeroForOne);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: !zeroForOne,
                amountIn: 1000e18,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            })
        );

        if (zeroForOne) {
            params[1] = abi.encode(key.currency1, 1000e18);
            params[2] = abi.encode(key.currency0, 0);
        } else {
            params[1] = abi.encode(key.currency0, 1000e18);
            params[2] = abi.encode(key.currency1, 0);
        }

        inputs[0] = abi.encode(actions, params);

        uint256 balBefore = usdt.balanceOf(account);
        uint256 wethBalBefore = weth.balanceOf(account);

        universalRouter.execute(commands, inputs, block.timestamp + 30 minutes);
        uint256 balAfter = usdt.balanceOf(account);
        uint256 wethBalAfter = weth.balanceOf(account);

        console.log("usdt balBefore: ", balBefore);
        console.log("usdt balAfter: ", balAfter);
        console.log("usdt diff: ", balBefore - balAfter);
        console.log("weth balBefore: ", wethBalBefore);
        console.log("weth balAfter: ", wethBalAfter);
        console.log("weth diff: ", wethBalAfter - wethBalBefore);
        vm.stopBroadcast();
    }

    function _addLiquidityV4WithHooks(address tokenA, address tokenB, uint256 tokenAAmount, uint256 tokenBAmount, address hookAddress) internal {
        // ETH 用 0x0000000000000000000000000000000000000000表示
        ERC20(tokenA).approve(address(permit2), type(uint256).max);
        ERC20(tokenB).approve(address(permit2), type(uint256).max);

        permit2.approve(tokenA, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(tokenB, address(positionManager), type(uint160).max, type(uint48).max);


        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (uint256 amount0, uint256 amount1) = tokenA < tokenB ? (tokenAAmount, tokenBAmount) : (tokenBAmount, tokenAAmount);

        uint160 sqrtPriceX96 = calculateSqrtPriceX96(tokenA, tokenB, tokenAAmount, tokenBAmount);
        console.log("sqrtPriceX96: ", uint256(sqrtPriceX96));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        positionManager.initializePool(poolKey, sqrtPriceX96);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](2);

        (int24 tickLower, int24 tickUpper) = calculateAMMRange(address(weth), address(usdt), 0, 0, 0, 0, 60);
        console.log("tickLower: ", tickLower);
        console.log("tickUpper: ", tickUpper);

        uint128 liquidity = getLiquidityForAmounts(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
        console.log("liquidity: ", liquidity);

        // PoolKey calldata poolKey,
        // int24 tickLower,
        // int24 tickUpper,
        // uint256 liquidity,
        // uint128 amount0Max,
        // uint128 amount1Max,
        // address owner,
        // bytes calldata hookData
        mintParams[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity - 10000, uint128(amount0), uint128(amount1), account, new bytes(0));
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, mintParams), block.timestamp + 30 minutes);
    }

    function testV4Quoter() public {
        address eth = address(0);
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address btc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

        PoolKey memory ethUsdcKey = createPoolKey(eth, usdc, address(0));
        PoolKey memory ethBtcKey = createPoolKey(eth, btc, address(0));
        PoolKey memory usdcBtcKey = createPoolKey(usdc, btc, address(0));

        (uint256 amountOut, uint256 gasEstimate) = v4Quoter.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams({
            poolKey: ethUsdcKey,
            zeroForOne: true,
            exactAmount: 1e18,
            hookData: new bytes(0)
        }));
        console.log("eth -> usdc");
        console.log("amountOut: ", amountOut);
        console.log("gasEstimate: ", gasEstimate);
        
        address[] memory tokenPath = new address[](3);
        tokenPath[0] = btc;
        tokenPath[1] = usdc;
        tokenPath[2] = eth;
        IV4Quoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 0.1e8);
        (amountOut, gasEstimate) = v4Quoter.quoteExactInput(params);
        console.log("btc -> usdc -> eth");
        console.log("amountOut: ", amountOut);
        console.log("gasEstimate: ", gasEstimate);
        
        (uint256 amountIn, uint256 exactOutGasEstimate) = v4Quoter.quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams({
            poolKey: ethUsdcKey,
            zeroForOne: true,
            exactAmount: 2500e6,
            hookData: new bytes(0)
        }));
        console.log("eth -> usdc");
        console.log("amountIn: ", amountIn);
        console.log("gasEstimate: ", exactOutGasEstimate);

        (amountIn, gasEstimate) = v4Quoter.quoteExactOutput(getExactOutputParams(tokenPath, 3e18));
        console.log("btc -> usdc -> eth");
        console.log("amountIn: ", amountIn);
        console.log("gasEstimate: ", gasEstimate);
    }

    function createPoolKey(address tokenA, address tokenB, address hookAddr)
        internal
        pure
        returns (PoolKey memory)
    {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey(Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), 3000, 60, IHooks(hookAddr));
    }

    function getExactInputParams(address[] memory _tokenPath, uint256 amountIn)
        internal
        pure
        returns (IV4Quoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(Currency.wrap(address(_tokenPath[i + 1])), 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.exactCurrency = Currency.wrap(address(_tokenPath[0]));
        params.path = path;
        params.exactAmount = uint128(amountIn);
    }

    function getExactOutputParams(address[] memory _tokenPath, uint256 amountOut)
        internal
        pure
        returns (IV4Quoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = _tokenPath.length - 1; i > 0; i--) {
            path[i - 1] = PathKey(Currency.wrap(address(_tokenPath[i - 1])), 3000, 60, IHooks(address(0)), bytes(""));
        }

        params.exactCurrency = Currency.wrap(address(_tokenPath[_tokenPath.length - 1]));
        params.path = path;
        params.exactAmount = uint128(amountOut);
    }

    function testV4SwapExactIn() public {
        vm.startBroadcast(account);

        _addLiquidityV4(address(weth), address(usdt), 1000e18, 2000_000e18);
        _addLiquidityV4(address(btc), address(usdt), 10e18, 700_000e18);
        
        // 设置通用变量
        uint256 amountInETH = 1e18;             // 1 ETH

        // 批准代币使用权限
        weth.approve(address(permit2), type(uint256).max);
        
        // 给permit2批准UniversalRouter的使用权限
        permit2.approve(address(weth), address(universalRouter), type(uint160).max, type(uint48).max);

        // 创建池子键值对
        PoolKey memory wethUsdtKey = createPoolKey(address(weth), address(usdt), address(0));
        PoolKey memory btcUsdtKey = createPoolKey(address(btc), address(usdt), address(0));
        
        // 1. Multi token pair exact input swap (ETH -> USDT -> BTC)
        console.log("==== Multi token pair exact input swap (ETH -> USDT -> BTC) ====");
        
        bytes memory commandsExactIn = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputsExactIn = new bytes[](1);
        
        // Build actions: SWAP_EXACT_IN + SETTLE_ALL + TAKE_ALL
        bytes memory actionsExactIn = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN), 
            uint8(Actions.SETTLE_ALL), 
            uint8(Actions.TAKE_ALL)
        );
        
        bytes[] memory paramsExactIn = new bytes[](3);
        
        // Build path
        Currency currencyInExactIn = Currency.wrap(address(weth));
        
        // Create path array: [ETH -> USDT, USDT -> BTC]
        PathKey[] memory pathExactIn = new PathKey[](2);
        pathExactIn[0] = PathKey(Currency.wrap(address(usdt)), 3000, 60, IHooks(address(0)), bytes(""));
        pathExactIn[1] = PathKey(Currency.wrap(address(btc)), 3000, 60, IHooks(address(0)), bytes(""));

        // Parameters for SWAP_EXACT_IN
        paramsExactIn[0] = abi.encode(
            IV4Router.ExactInputParams({
                currencyIn: currencyInExactIn,
                path: pathExactIn,
                amountIn: uint128(amountInETH),
                amountOutMinimum: uint128(0)
            })
        );
        
        // Parameters for SETTLE_ALL (ETH settlement)
        paramsExactIn[1] = abi.encode(currencyInExactIn, amountInETH);
        
        // Parameters for TAKE_ALL (receive BTC)
        paramsExactIn[2] = abi.encode(Currency.wrap(address(btc)), 0);
        
        inputsExactIn[0] = abi.encode(actionsExactIn, paramsExactIn);
        
        // Execute transaction
        uint256 balBeforeExactIn = btc.balanceOf(account);
        universalRouter.execute(commandsExactIn, inputsExactIn, block.timestamp + 30 minutes);
        uint256 balAfterExactIn = btc.balanceOf(account);
        console.log("BTC received: ", balAfterExactIn - balBeforeExactIn);
        vm.stopBroadcast();
    }

    function testV4SwapExactOutSingle() public {
        vm.startBroadcast(account);

        _addLiquidityV4(address(weth), address(usdt), 1000e18, 2000_000e18);
        _addLiquidityV4(address(btc), address(usdt), 10e18, 700_000e18);
        
        // 设置通用变量
        uint256 amountInETHMax = 2e18; // 2 ETH

        // 批准代币使用权限
        weth.approve(address(permit2), type(uint256).max);
        
        // 给permit2批准UniversalRouter的使用权限
        permit2.approve(address(weth), address(universalRouter), type(uint160).max, type(uint48).max);

        // 创建池子键值对
        PoolKey memory wethUsdtKey = createPoolKey(address(weth), address(usdt), address(0));
        PoolKey memory btcUsdtKey = createPoolKey(address(btc), address(usdt), address(0));
        
        // 3. Single token pair exact output swap (ETH -> USDC)
        console.log("==== Single token pair exact output swap (ETH -> USDC) ====");
        
        bytes memory commandsExactOutSingle = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputsExactOutSingle = new bytes[](1);
        
        // Build actions: SWAP_EXACT_OUT_SINGLE + SETTLE_ALL + TAKE_ALL
        bytes memory actionsExactOutSingle = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), 
            uint8(Actions.SETTLE_ALL), 
            uint8(Actions.TAKE_ALL)
        );
        
        bytes[] memory paramsExactOutSingle = new bytes[](3);
        
        // Parameters for SWAP_EXACT_OUT_SINGLE
        paramsExactOutSingle[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: wethUsdtKey,
                zeroForOne: address(weth) < address(usdt),  // ETH -> USDC
                amountOut: uint128(2000e18),
                amountInMaximum: uint128(amountInETHMax),
                hookData: new bytes(0)
            })
        );
        
        // Parameters for SETTLE_ALL (ETH settlement)
        paramsExactOutSingle[1] = abi.encode(Currency.wrap(address(weth)), type(uint256).max);
        
        // Parameters for TAKE_ALL (receive USDC)
        paramsExactOutSingle[2] = abi.encode(Currency.wrap(address(usdt)), 0);
        
        inputsExactOutSingle[0] = abi.encode(actionsExactOutSingle, paramsExactOutSingle);
        
        // Execute transaction
        uint256 balBeforeExactOutSingle = usdt.balanceOf(account);
        universalRouter.execute(commandsExactOutSingle, inputsExactOutSingle, block.timestamp + 30 minutes);
        uint256 balAfterExactOutSingle = usdt.balanceOf(account);
        console.log("USDT received: ", balAfterExactOutSingle - balBeforeExactOutSingle);
        vm.stopBroadcast();
    }

    function testV4SwapExactOut() public {
        vm.startBroadcast(account);

        _addLiquidityV4(address(weth), address(usdt), 1000e18, 2000_000e18);
        _addLiquidityV4(address(btc), address(usdt), 10e18, 700_000e18);
        
        // 设置通用变量
        uint256 amountInETHMax = 2e18;             // 2 ETH

        // 批准代币使用权限
        weth.approve(address(permit2), type(uint256).max);
        
        // 给permit2批准UniversalRouter的使用权限
        permit2.approve(address(weth), address(universalRouter), type(uint160).max, type(uint48).max);

        // 创建池子键值对
        PoolKey memory wethUsdtKey = createPoolKey(address(weth), address(usdt), address(0));
        PoolKey memory btcUsdtKey = createPoolKey(address(btc), address(usdt), address(0));
        
        // Multi token pair exact output swap (ETH -> USDC -> BTC)
        console.log("==== Multi token pair exact output swap (ETH -> USDC -> BTC) ====");
        
        bytes memory commandsExactOut = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputsExactOut = new bytes[](1);
        
        // Build actions: SWAP_EXACT_OUT + SETTLE_ALL + TAKE_ALL
        bytes memory actionsExactOut = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT), 
            uint8(Actions.SETTLE_ALL), 
            uint8(Actions.TAKE_ALL)
        );
        
        bytes[] memory paramsExactOut = new bytes[](3);
        
        // Set target output token
        Currency currencyOutExactOut = Currency.wrap(address(btc));
        
        // Create reverse path array: BTC <- USDC <- ETH (note path is reverse)
        PathKey[] memory pathExactOut = new PathKey[](2);
        pathExactOut[0] = PathKey(Currency.wrap(address(weth)), 3000, 60, IHooks(address(0)), bytes(""));
        pathExactOut[1] = PathKey(Currency.wrap(address(usdt)), 3000, 60, IHooks(address(0)), bytes(""));
        
        // Parameters for SWAP_EXACT_OUT
        paramsExactOut[0] = abi.encode(
            IV4Router.ExactOutputParams({
                currencyOut: currencyOutExactOut,
                path: pathExactOut,
                amountOut: uint128(0.01e18),
                amountInMaximum: uint128(amountInETHMax)
            })
        );
        
        // Parameters for SETTLE_ALL (ETH settlement)
        paramsExactOut[1] = abi.encode(Currency.wrap(address(weth)), type(uint256).max);
        
        // Parameters for TAKE_ALL (receive BTC)
        paramsExactOut[2] = abi.encode(currencyOutExactOut, 0);
        
        inputsExactOut[0] = abi.encode(actionsExactOut, paramsExactOut);
        
        // Execute transaction
        uint256 balBeforeExactOut = IERC20(btc).balanceOf(account);
        universalRouter.execute(commandsExactOut, inputsExactOut, block.timestamp + 30 minutes);
        uint256 balAfterExactOut = IERC20(btc).balanceOf(account);
        console.log("BTC received: ", balAfterExactOut - balBeforeExactOut);
        vm.stopBroadcast();
    }

    /// @notice 计算在Uniswap中给定tokenA和tokenB数量的sqrtPriceX96
    /// @param tokenA 交易对中的第一个代币地址
    /// @param tokenB 交易对中的第二个代币地址
    /// @param tokenAAmount tokenA的数量
    /// @param tokenBAmount tokenB的数量
    /// @return sqrtPriceX96 计算得到的sqrtPriceX96
    function calculateSqrtPriceX96(
        address tokenA,
        address tokenB,
        uint256 tokenAAmount,
        uint256 tokenBAmount
    ) internal pure returns (uint160 sqrtPriceX96) {
        (uint256 token0Amount, uint256 token1Amount) = tokenA < tokenB ? (tokenAAmount, tokenBAmount) : (tokenBAmount, tokenAAmount);

        // token1Amount * 2**192 / token0Amount
        uint256 priceX192 = FullMath.mulDiv(token1Amount, 2**192, token0Amount);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));
    }

    /// @notice 计算在Uniswap中给定tokenA和tokenB数量的tick范围
    /// @param tokenA 交易对中的第一个代币地址
    /// @param tokenB 交易对中的第二个代币地址
    /// @param tokenAAmountLower tokenA的数量
    /// @param tokenBAmountLower tokenB的数量
    /// @param tokenAAmountUpper tokenA的数量
    /// @param tokenBAmountUpper tokenB的数量
    /// @param tickSpacing tick的步长
    /// @return tickLower 计算得到的tick下限
    /// @return tickUpper 计算得到的tick上限
    function calculateAMMRange(
        address tokenA,
        address tokenB,
        uint256 tokenAAmountLower,
        uint256 tokenBAmountLower,
        uint256 tokenAAmountUpper,
        uint256 tokenBAmountUpper,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        if (tokenAAmountLower == 0 && tokenBAmountLower == 0 && tokenAAmountUpper == 0 && tokenBAmountUpper == 0) {
            tickLower = MIN_TICK - (MIN_TICK % tickSpacing);
            tickUpper = MAX_TICK - (MAX_TICK % tickSpacing);
            return (tickLower, tickUpper);
        }
        
        uint160 sqrtPriceX96Lower = calculateSqrtPriceX96(tokenA, tokenB, tokenAAmountLower, tokenBAmountLower);
        uint160 sqrtPriceX96Upper = calculateSqrtPriceX96(tokenA, tokenB, tokenAAmountUpper, tokenBAmountUpper);

        // price = (sqrtPriceX96 / 2**96)**2
        // tick = Math.log(price) / Math.log(1.0001)
        int24 tickL = TickMath.getTickAtSqrtPrice(sqrtPriceX96Lower);
        int24 tickU = TickMath.getTickAtSqrtPrice(sqrtPriceX96Upper);

        tickL = tickL - (tickL % tickSpacing);
        tickU = tickU - (tickU % tickSpacing);

        if (tickL > tickU) {
            tickLower = tickU;
            tickUpper = tickL;
        } else {
            tickLower = tickL;
            tickUpper = tickU;
        }
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
    }
}
