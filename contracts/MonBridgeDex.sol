// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal interfaces for Uniswap V2-style routers, factories, pairs, and ERC20 tokens.
interface IUniswapV2Router02 {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function factory() external pure returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Uniswap V3 SwapRouter02 interface
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @notice Uniswap V3 Factory interface
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

/// @notice Uniswap V3 Pool interface
interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

/// @notice Quoter V2 interface for getting quotes
interface IQuoterV2 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    function quoteExactInput(
        bytes memory path,
        uint256 amountIn
    ) external returns (uint256 amountOut, uint160[] memory sqrtPriceX96AfterList, uint32[] memory initializedTicksCrossedList, uint256 gasEstimate);
}

interface IERC20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @title MonBridgeDex V3 Enhanced
/// @notice Advanced DEX aggregator with V2 and V3 support, transfer fee handling, and intelligent route optimization
contract MonBridgeDex {
    address public owner;
    address[] public v2Routers;
    address[] public v3Routers;
    mapping(address => address) public v3RouterToFactory; // V3 router -> factory mapping
    mapping(address => address) public v3RouterToQuoter;  // V3 router -> quoter mapping
    mapping(address => bool) public v2RouterExists;
    mapping(address => bool) public v3RouterExists;

    uint public constant MAX_ROUTERS = 100;
    uint public feeAccumulatedETH;
    mapping(address => uint) public feeAccumulatedTokens;

    // Fee divisor: fee = amount / FEE_DIVISOR (0.1% fee)
    uint public constant FEE_DIVISOR = 1000;
    address public WETH;

    // Standard V3 fee tiers (in hundredths of a bip)
    uint24[] public standardFeeTiers = [100, 500, 3000, 10000]; // 0.01%, 0.05%, 0.3%, 1%

    // Reentrancy guard
    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // Enhanced trade types
    enum TradeType {
        ETH_TO_TOKEN,
        TOKEN_TO_ETH,
        TOKEN_TO_TOKEN,
        ETH_TO_TOKEN_FEE_ON_TRANSFER,
        TOKEN_TO_ETH_FEE_ON_TRANSFER,
        TOKEN_TO_TOKEN_FEE_ON_TRANSFER
    }

    enum ProtocolType {
        V2,
        V3
    }

    struct TradeParams {
        TradeType tradeType;
        uint amountIn;
        uint amountOutMin;
        address[] path;
        uint deadline;
        bool supportsFeeOnTransfer;
    }

    struct RouteInfo {
        ProtocolType protocol;
        address router;
        uint amountOut;
        uint gasEstimate;
        bytes extraData; // For V3: contains fee tier or multi-hop path
    }

    struct V3RouteData {
        uint24 feeTier;
        bytes multiHopPath; // Encoded path for multi-hop swaps
        bool isMultiHop;
    }

    event V2RouterAdded(address router);
    event V3RouterAdded(address router, address factory, address quoter);
    event RouterRemoved(address router, ProtocolType protocol);
    event TradeExecuted(
        address indexed user,
        address router,
        ProtocolType protocol,
        TradeType tradeType,
        uint amountIn,
        uint amountOut
    );
    event BestRouteFound(
        address router,
        ProtocolType protocol,
        uint amountOut,
        uint gasEstimate
    );

    constructor(address _weth) {
        owner = msg.sender;
        WETH = _weth;
    }

    /// @notice Add multiple V2 routers at once
    function addV2Routers(address[] calldata _routers) external onlyOwner {
        require(v2Routers.length + _routers.length <= MAX_ROUTERS, "Exceeds max routers");

        for (uint i = 0; i < _routers.length; i++) {
            require(_routers[i] != address(0), "Invalid router address");
            require(!v2RouterExists[_routers[i]], "Router already exists");

            v2Routers.push(_routers[i]);
            v2RouterExists[_routers[i]] = true;
            emit V2RouterAdded(_routers[i]);
        }
    }

    /// @notice Add V3 router with its factory and quoter
    function addV3Router(address _router, address _factory, address _quoter) external onlyOwner {
        require(v3Routers.length < MAX_ROUTERS, "Max routers reached");
        require(_router != address(0) && _factory != address(0) && _quoter != address(0), "Invalid addresses");
        require(!v3RouterExists[_router], "Router already exists");

        v3Routers.push(_router);
        v3RouterExists[_router] = true;
        v3RouterToFactory[_router] = _factory;
        v3RouterToQuoter[_router] = _quoter;

        emit V3RouterAdded(_router, _factory, _quoter);
    }

    /// @notice Add multiple V3 routers with their factories and quoters
    function addV3Routers(
        address[] calldata _routers,
        address[] calldata _factories,
        address[] calldata _quoters
    ) external onlyOwner {
        require(_routers.length == _factories.length && _routers.length == _quoters.length, "Array length mismatch");
        require(v3Routers.length + _routers.length <= MAX_ROUTERS, "Exceeds max routers");

        for (uint i = 0; i < _routers.length; i++) {
            require(_routers[i] != address(0) && _factories[i] != address(0) && _quoters[i] != address(0), "Invalid addresses");
            require(!v3RouterExists[_routers[i]], "Router already exists");

            v3Routers.push(_routers[i]);
            v3RouterExists[_routers[i]] = true;
            v3RouterToFactory[_routers[i]] = _factories[i];
            v3RouterToQuoter[_routers[i]] = _quoters[i];

            emit V3RouterAdded(_routers[i], _factories[i], _quoters[i]);
        }
    }

    /// @notice Remove V2 router
    function removeV2Router(address _router) external onlyOwner {
        require(v2RouterExists[_router], "Router does not exist");

        for (uint i = 0; i < v2Routers.length; i++) {
            if (v2Routers[i] == _router) {
                v2Routers[i] = v2Routers[v2Routers.length - 1];
                v2Routers.pop();
                v2RouterExists[_router] = false;
                emit RouterRemoved(_router, ProtocolType.V2);
                break;
            }
        }
    }

    /// @notice Remove V3 router
    function removeV3Router(address _router) external onlyOwner {
        require(v3RouterExists[_router], "Router does not exist");

        for (uint i = 0; i < v3Routers.length; i++) {
            if (v3Routers[i] == _router) {
                v3Routers[i] = v3Routers[v3Routers.length - 1];
                v3Routers.pop();
                v3RouterExists[_router] = false;
                delete v3RouterToFactory[_router];
                delete v3RouterToQuoter[_router];
                emit RouterRemoved(_router, ProtocolType.V3);
                break;
            }
        }
    }

    /// @notice Get the best route across all V2 and V3 routers (VIEW FUNCTION - NO GAS COST)
    /// @param amountIn Input amount
    /// @param tokenIn Input token address (use address(0) for ETH)
    /// @param tokenOut Output token address (use address(0) for ETH)
    /// @return bestRoute Complete route information with best pricing
    function getBestRouter(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (RouteInfo memory bestRoute) {
        require(amountIn > 0, "Invalid amount");
        require(tokenIn != tokenOut, "Same token");

        // Validate ETH cases - both can't be ETH
        require(!(tokenIn == address(0) && tokenOut == address(0)), "Both tokens cannot be ETH");

        // Get best routes from both protocols with resilient error handling
        RouteInfo memory bestV2Route = _getBestV2RouteResilient(amountIn, tokenIn, tokenOut);
        RouteInfo memory bestV3Route = _getBestV3RouteResilient(amountIn, tokenIn, tokenOut);

        // Compare V2 vs V3 routes
        if (bestV2Route.amountOut == 0 && bestV3Route.amountOut == 0) {
            // Return empty route instead of reverting to maintain view function property
            return RouteInfo({
                protocol: ProtocolType.V2,
                router: address(0),
                amountOut: 0,
                gasEstimate: 0,
                extraData: ""
            });
        }

        if (bestV2Route.amountOut == 0) {
            return bestV3Route;
        }

        if (bestV3Route.amountOut == 0) {
            return bestV2Route;
        }

        // Choose the route with higher output amount
        if (bestV3Route.amountOut > bestV2Route.amountOut) {
            return bestV3Route;
        } else {
            return bestV2Route;
        }
    }

    /// @notice Find best V2 route with resilient error handling and proper WETH conversion
    function _getBestV2RouteResilient(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteInfo memory bestRoute) {
        // Proper ETH/WETH handling - convert ETH (address(0)) to WETH for routing
        address actualTokenIn = tokenIn == address(0) ? WETH : tokenIn;
        address actualTokenOut = tokenOut == address(0) ? WETH : tokenOut;

        // Ensure we have valid token addresses
        if (actualTokenIn == address(0) || actualTokenOut == address(0)) {
            return bestRoute; // Return empty route
        }

        // Try each router individually with error isolation
        for (uint i = 0; i < v2Routers.length; i++) {
            address router = v2Routers[i];
            
            // Skip if router address is invalid
            if (router == address(0)) continue;

            RouteInfo memory currentBest = _tryV2RouterSafely(router, amountIn, actualTokenIn, actualTokenOut);
            
            if (currentBest.amountOut > bestRoute.amountOut) {
                bestRoute = currentBest;
            }
        }
    }

    /// @notice Safely try V2 router with comprehensive error handling
    function _tryV2RouterSafely(
        address router,
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteInfo memory bestRouteForRouter) {
        // Try different path strategies safely
        
        // 1. Direct path: tokenIn -> tokenOut
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;
        
        RouteInfo memory directRoute = _tryV2PathSafely(router, amountIn, directPath);
        if (directRoute.amountOut > bestRouteForRouter.amountOut) {
            bestRouteForRouter = directRoute;
        }

        // 2. WETH hop path: tokenIn -> WETH -> tokenOut (only if both tokens are not WETH)
        if (tokenIn != WETH && tokenOut != WETH) {
            address[] memory wethHopPath = new address[](3);
            wethHopPath[0] = tokenIn;
            wethHopPath[1] = WETH;
            wethHopPath[2] = tokenOut;
            
            RouteInfo memory wethRoute = _tryV2PathSafely(router, amountIn, wethHopPath);
            if (wethRoute.amountOut > bestRouteForRouter.amountOut) {
                bestRouteForRouter = wethRoute;
            }
        }
    }

    /// @notice Safely try a specific V2 path
    function _tryV2PathSafely(
        address router, 
        uint amountIn, 
        address[] memory path
    ) internal view returns (RouteInfo memory routeInfo) {
        // Validate path
        if (path.length < 2) return routeInfo;
        
        try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                routeInfo = RouteInfo({
                    protocol: ProtocolType.V2,
                    router: router,
                    amountOut: amounts[amounts.length - 1],
                    gasEstimate: _calculateGasEstimate(path.length),
                    extraData: abi.encode(path)
                });
            }
        } catch {
            // Silently ignore errors and return empty route
        }
    }

    /// @notice Get ETH-optimized path for better routing
    function _getEthOptimizedPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
        // Common high-liquidity tokens that often provide better routes
        address[] memory commonIntermediaries = new address[](1);
        commonIntermediaries[0] = WETH;
        // Add other common tokens like USDC, USDT if available
        // For now, focusing on WETH as the primary intermediary

        if (tokenIn != WETH && tokenOut != WETH) {
            address[] memory path = new address[](3);
            path[0] = tokenIn;
            path[1] = WETH;
            path[2] = tokenOut;
            return path;
        }

        // Return direct path if one token is already WETH
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;
        return directPath;
    }

    /// @notice Calculate gas estimate based on path length
    function _calculateGasEstimate(uint pathLength) internal pure returns (uint) {
        if (pathLength == 2) return 150000;
        if (pathLength == 3) return 200000;
        if (pathLength == 4) return 280000;
        return 350000; // For longer paths
    }

    /// @notice Check if we should explore more complex routes
    function _shouldExploreMoreHops(uint currentBestAmount, uint amountIn) internal pure returns (bool) {
        // Explore more if we haven't found a good route (less than 90% of input for same token trades)
        return currentBestAmount < (amountIn * 90) / 100;
    }

    /// @notice Explore complex multi-hop V2 routes
    function _exploreComplexV2Routes(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteInfo memory bestComplexRoute) {
        // Define additional common intermediary tokens for better routing
        address[] memory intermediaries = new address[](1);
        intermediaries[0] = WETH;

        // Try 4-hop routes: tokenIn -> intermediary1 -> WETH -> tokenOut
        for (uint i = 0; i < v2Routers.length; i++) {
            address router = v2Routers[i];

            for (uint j = 0; j < intermediaries.length; j++) {
                address intermediary = intermediaries[j];

                if (intermediary != tokenIn && intermediary != tokenOut) {
                    address[] memory complexPath = new address[](4);
                    complexPath[0] = tokenIn;
                    complexPath[1] = intermediary;
                    complexPath[2] = WETH;
                    complexPath[3] = tokenOut;

                    try IUniswapV2Router02(router).getAmountsOut(amountIn, complexPath)
                        returns (uint[] memory amounts) {
                        uint amountOut = amounts[amounts.length - 1];
                        if (amountOut > bestComplexRoute.amountOut) {
                            bestComplexRoute = RouteInfo({
                                protocol: ProtocolType.V2,
                                router: router,
                                amountOut: amountOut,
                                gasEstimate: 280000,
                                extraData: abi.encode(complexPath)
                            });
                        }
                    } catch {
                        continue;
                    }
                }
            }
        }
    }

    /// @notice Find best V3 route with resilient error handling
    function _getBestV3RouteResilient(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteInfo memory bestRoute) {
        // Handle ETH address conversion for V3 - WETH is used in V3
        address actualTokenIn = tokenIn == address(0) ? WETH : tokenIn;
        address actualTokenOut = tokenOut == address(0) ? WETH : tokenOut;

        // Validate addresses
        if (actualTokenIn == address(0) || actualTokenOut == address(0)) {
            return bestRoute; // Return empty route
        }

        // Try each V3 router individually with error isolation
        for (uint i = 0; i < v3Routers.length; i++) {
            address router = v3Routers[i];
            address factory = v3RouterToFactory[router];
            
            // Skip if router or factory is not properly configured
            if (router == address(0) || factory == address(0)) continue;
            
            RouteInfo memory routerBest = _tryV3RouterSafely(router, factory, amountIn, actualTokenIn, actualTokenOut);
            
            if (routerBest.amountOut > bestRoute.amountOut) {
                bestRoute = routerBest;
            }
        }
    }

    /// @notice Safely try V3 router with comprehensive error handling
    function _tryV3RouterSafely(
        address router,
        address factory,
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteInfo memory bestRouteForRouter) {
        
        // Try direct swaps across all fee tiers
        for (uint j = 0; j < standardFeeTiers.length; j++) {
            uint24 fee = standardFeeTiers[j];
            
            try IUniswapV3Factory(factory).getPool(tokenIn, tokenOut, fee) returns (address pool) {
                if (pool != address(0)) {
                    (uint256 amountOut, uint256 gasEstimate) = _calculateV3SwapOutputSafely(
                        pool, tokenIn, tokenOut, amountIn, fee
                    );

                    if (amountOut > bestRouteForRouter.amountOut) {
                        bestRouteForRouter = RouteInfo({
                            protocol: ProtocolType.V3,
                            router: router,
                            amountOut: amountOut,
                            gasEstimate: gasEstimate,
                            extraData: abi.encode(V3RouteData({
                                feeTier: fee,
                                multiHopPath: "",
                                isMultiHop: false
                            }))
                        });
                    }
                }
            } catch {
                // Silently continue to next fee tier
                continue;
            }
        }

        // Try multi-hop via WETH for token-to-token swaps only
        if (tokenIn != WETH && tokenOut != WETH) {
            RouteInfo memory multiHopRoute = _tryV3MultiHopSafely(router, factory, amountIn, tokenIn, tokenOut);
            if (multiHopRoute.amountOut > bestRouteForRouter.amountOut) {
                bestRouteForRouter = multiHopRoute;
            }
        }
    }

    /// @notice Safely try V3 multi-hop routing
    function _tryV3MultiHopSafely(
        address router,
        address factory,
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteInfo memory bestMultiHop) {
        
        for (uint j = 0; j < standardFeeTiers.length; j++) {
            for (uint k = 0; k < standardFeeTiers.length; k++) {
                uint24 fee1 = standardFeeTiers[j];
                uint24 fee2 = standardFeeTiers[k];

                try IUniswapV3Factory(factory).getPool(tokenIn, WETH, fee1) returns (address pool1) {
                    try IUniswapV3Factory(factory).getPool(WETH, tokenOut, fee2) returns (address pool2) {
                        if (pool1 != address(0) && pool2 != address(0)) {
                            // Calculate first hop
                            (uint256 intermediateOut,) = _calculateV3SwapOutputSafely(pool1, tokenIn, WETH, amountIn, fee1);
                            
                            if (intermediateOut > 0) {
                                // Calculate second hop
                                (uint256 finalOut, uint256 totalGas) = _calculateV3SwapOutputSafely(pool2, WETH, tokenOut, intermediateOut, fee2);

                                if (finalOut > bestMultiHop.amountOut) {
                                    bytes memory path = abi.encodePacked(tokenIn, fee1, WETH, fee2, tokenOut);
                                    
                                    bestMultiHop = RouteInfo({
                                        protocol: ProtocolType.V3,
                                        router: router,
                                        amountOut: finalOut,
                                        gasEstimate: totalGas + 100000,
                                        extraData: abi.encode(V3RouteData({
                                            feeTier: 0,
                                            multiHopPath: path,
                                            isMultiHop: true
                                        }))
                                    });
                                }
                            }
                        }
                    } catch {
                        // Silently continue if second pool lookup fails
                        continue;
                    }
                } catch {
                    // Silently continue if first pool lookup fails
                    continue;
                }
            }
        }
    }

    /// @notice Execute trade using the optimal route
    /// @param routeInfo Route information from getBestRouter
    /// @param params Trade parameters
    function executeOptimalTrade(
        RouteInfo calldata routeInfo,
        TradeParams calldata params
    ) external payable nonReentrant returns (uint amountOut) {
        require(params.deadline >= block.timestamp, "Deadline expired");
        require(routeInfo.amountOut >= params.amountOutMin, "Insufficient output amount");

        // Verify router is whitelisted
        if (routeInfo.protocol == ProtocolType.V2) {
            require(v2RouterExists[routeInfo.router], "V2 router not whitelisted");
        } else {
            require(v3RouterExists[routeInfo.router], "V3 router not whitelisted");
        }

        if (routeInfo.protocol == ProtocolType.V2) {
            return _executeV2Trade(routeInfo, params);
        } else {
            return _executeV3Trade(routeInfo, params);
        }
    }

    /// @notice Execute V2 trade
    function _executeV2Trade(
        RouteInfo memory routeInfo,
        TradeParams memory params
    ) internal returns (uint amountOut) {
        address[] memory path;

        // Decode path from extraData if it exists (multi-hop), otherwise use simple path
        if (routeInfo.extraData.length > 0) {
            path = abi.decode(routeInfo.extraData, (address[]));
        } else {
            path = params.path;
        }

        if (params.tradeType == TradeType.ETH_TO_TOKEN ||
            params.tradeType == TradeType.ETH_TO_TOKEN_FEE_ON_TRANSFER) {

            uint fee = msg.value / FEE_DIVISOR;
            uint amountForSwap = msg.value - fee;
            feeAccumulatedETH += fee;

            if (params.supportsFeeOnTransfer) {
                IUniswapV2Router02(routeInfo.router).swapExactETHForTokensSupportingFeeOnTransferTokens{
                    value: amountForSwap
                }(params.amountOutMin, path, msg.sender, params.deadline);
                // Calculate actual received amount for fee-on-transfer tokens
                amountOut = routeInfo.amountOut; // Approximation
            } else {
                uint[] memory amounts = IUniswapV2Router02(routeInfo.router).swapExactETHForTokens{
                    value: amountForSwap
                }(params.amountOutMin, path, msg.sender, params.deadline);
                amountOut = amounts[amounts.length - 1];
            }
        } else if (params.tradeType == TradeType.TOKEN_TO_ETH ||
                   params.tradeType == TradeType.TOKEN_TO_ETH_FEE_ON_TRANSFER) {

            require(IERC20(path[0]).transferFrom(msg.sender, address(this), params.amountIn), "Transfer failed");

            uint fee = params.amountIn / FEE_DIVISOR;
            uint amountForSwap = params.amountIn - fee;
            feeAccumulatedTokens[path[0]] += fee;

            require(IERC20(path[0]).approve(routeInfo.router, amountForSwap), "Approve failed");

            if (params.supportsFeeOnTransfer) {
                IUniswapV2Router02(routeInfo.router).swapExactTokensForETHSupportingFeeOnTransferTokens(
                    amountForSwap, params.amountOutMin, path, msg.sender, params.deadline
                );
                amountOut = routeInfo.amountOut; // Approximation
            } else {
                uint[] memory amounts = IUniswapV2Router02(routeInfo.router).swapExactTokensForETH(
                    amountForSwap, params.amountOutMin, path, msg.sender, params.deadline
                );
                amountOut = amounts[amounts.length - 1];
            }
        } else {
            // TOKEN_TO_TOKEN
            require(IERC20(path[0]).transferFrom(msg.sender, address(this), params.amountIn), "Transfer failed");

            uint fee = params.amountIn / FEE_DIVISOR;
            uint amountForSwap = params.amountIn - fee;
            feeAccumulatedTokens[path[0]] += fee;

            require(IERC20(path[0]).approve(routeInfo.router, amountForSwap), "Approve failed");

            if (params.supportsFeeOnTransfer) {
                IUniswapV2Router02(routeInfo.router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amountForSwap, params.amountOutMin, path, msg.sender, params.deadline
                );
                amountOut = routeInfo.amountOut; // Approximation
            } else {
                uint[] memory amounts = IUniswapV2Router02(routeInfo.router).swapExactTokensForTokens(
                    amountForSwap, params.amountOutMin, path, msg.sender, params.deadline
                );
                amountOut = amounts[amounts.length - 1];
            }
        }

        emit TradeExecuted(msg.sender, routeInfo.router, ProtocolType.V2, params.tradeType, params.amountIn, amountOut);
    }

    /// @notice Safely calculate V3 swap output with error handling
    function _calculateV3SwapOutputSafely(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee
    ) internal view returns (uint256 amountOut, uint256 gasEstimate) {
        if (amountIn == 0) return (0, 0);

        try IUniswapV3Pool(pool).slot0() returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16,
            uint16,
            uint16,
            uint8,
            bool unlocked
        ) {
            if (!unlocked || sqrtPriceX96 == 0) return (0, 0);

            uint128 liquidity = IUniswapV3Pool(pool).liquidity();
            if (liquidity == 0) return (0, 0);

            address token0 = IUniswapV3Pool(pool).token0();
            bool zeroForOne = tokenIn == token0;

            // Calculate fee amount
            uint256 feeAmount = (amountIn * fee) / 1000000;
            uint256 amountInAfterFee = amountIn - feeAmount;

            // Simplified price calculation using current pool state
            // This approximates the swap without complex math libraries
            if (zeroForOne) {
                // token0 -> token1
                uint256 numerator = amountInAfterFee * uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
                uint256 denominator = (1 << 192) + (amountInAfterFee * uint256(sqrtPriceX96)) / uint256(liquidity);
                amountOut = numerator / denominator;
            } else {
                // token1 -> token0
                uint256 denominator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
                amountOut = (amountInAfterFee * (1 << 192)) / denominator;

                // Adjust for liquidity
                uint256 liquidityAdjustment = (amountInAfterFee * (1 << 96)) / uint256(liquidity);
                if (liquidityAdjustment < amountOut) {
                    amountOut = amountOut - liquidityAdjustment;
                }
            }

            // Apply slippage reduction for larger trades (approximation)
            if (amountIn > uint256(liquidity) / 100) {
                uint256 slippageReduction = (amountIn * 50) / uint256(liquidity); // Max 5% slippage approximation
                if (slippageReduction > 500) slippageReduction = 500; // Cap at 5%
                amountOut = (amountOut * (10000 - slippageReduction)) / 10000;
            }

            gasEstimate = 150000; // Base V3 swap gas

        } catch {
            return (0, 0);
        }
    }

    /// @notice Execute V3 trade
    function _executeV3Trade(
        RouteInfo memory routeInfo,
        TradeParams memory params
    ) internal returns (uint amountOut) {
        V3RouteData memory routeData = abi.decode(routeInfo.extraData, (V3RouteData));

        if (params.tradeType == TradeType.ETH_TO_TOKEN ||
            params.tradeType == TradeType.ETH_TO_TOKEN_FEE_ON_TRANSFER) {

            uint fee = msg.value / FEE_DIVISOR;
            uint amountForSwap = msg.value - fee;
            feeAccumulatedETH += fee;

            if (routeData.isMultiHop) {
                ISwapRouter02.ExactInputParams memory swapParams = ISwapRouter02.ExactInputParams({
                    path: routeData.multiHopPath,
                    recipient: msg.sender,
                    amountIn: amountForSwap,
                    amountOutMinimum: params.amountOutMin
                });
                amountOut = ISwapRouter02(routeInfo.router).exactInput{value: amountForSwap}(swapParams);
            } else {
                ISwapRouter02.ExactInputSingleParams memory swapParams = ISwapRouter02.ExactInputSingleParams({
                    tokenIn: WETH, // V3 always uses WETH for ETH trades
                    tokenOut: params.path[1],
                    fee: routeData.feeTier,
                    recipient: msg.sender,
                    amountIn: amountForSwap,
                    amountOutMinimum: params.amountOutMin,
                    sqrtPriceLimitX96: 0
                });
                amountOut = ISwapRouter02(routeInfo.router).exactInputSingle{value: amountForSwap}(swapParams);
            }
        } else if (params.tradeType == TradeType.TOKEN_TO_ETH ||
                   params.tradeType == TradeType.TOKEN_TO_ETH_FEE_ON_TRANSFER) {
            // TOKEN_TO_ETH - special handling for ETH output
            require(IERC20(params.path[0]).transferFrom(msg.sender, address(this), params.amountIn), "Transfer failed");

            uint fee = params.amountIn / FEE_DIVISOR;
            uint amountForSwap = params.amountIn - fee;
            feeAccumulatedTokens[params.path[0]] += fee;

            require(IERC20(params.path[0]).approve(routeInfo.router, amountForSwap), "Approve failed");

            if (routeData.isMultiHop) {
                ISwapRouter02.ExactInputParams memory swapParams = ISwapRouter02.ExactInputParams({
                    path: routeData.multiHopPath,
                    recipient: msg.sender,
                    amountIn: amountForSwap,
                    amountOutMinimum: params.amountOutMin
                });
                amountOut = ISwapRouter02(routeInfo.router).exactInput(swapParams);
            } else {
                ISwapRouter02.ExactInputSingleParams memory swapParams = ISwapRouter02.ExactInputSingleParams({
                    tokenIn: params.path[0],
                    tokenOut: WETH, // V3 uses WETH for ETH output
                    fee: routeData.feeTier,
                    recipient: msg.sender,
                    amountIn: amountForSwap,
                    amountOutMinimum: params.amountOutMin,
                    sqrtPriceLimitX96: 0
                });
                amountOut = ISwapRouter02(routeInfo.router).exactInputSingle(swapParams);
            }
        } else {
            // TOKEN_TO_TOKEN
            require(IERC20(params.path[0]).transferFrom(msg.sender, address(this), params.amountIn), "Transfer failed");

            uint fee = params.amountIn / FEE_DIVISOR;
            uint amountForSwap = params.amountIn - fee;
            feeAccumulatedTokens[params.path[0]] += fee;

            require(IERC20(params.path[0]).approve(routeInfo.router, amountForSwap), "Approve failed");

            if (routeData.isMultiHop) {
                ISwapRouter02.ExactInputParams memory swapParams = ISwapRouter02.ExactInputParams({
                    path: routeData.multiHopPath,
                    recipient: msg.sender,
                    amountIn: amountForSwap,
                    amountOutMinimum: params.amountOutMin
                });
                amountOut = ISwapRouter02(routeInfo.router).exactInput(swapParams);
            } else {
                ISwapRouter02.ExactInputSingleParams memory swapParams = ISwapRouter02.ExactInputSingleParams({
                    tokenIn: params.path[0],
                    tokenOut: params.path[1],
                    fee: routeData.feeTier,
                    recipient: msg.sender,
                    amountIn: amountForSwap,
                    amountOutMinimum: params.amountOutMin,
                    sqrtPriceLimitX96: 0
                });
                amountOut = ISwapRouter02(routeInfo.router).exactInputSingle(swapParams);
            }
        }

        emit TradeExecuted(msg.sender, routeInfo.router, ProtocolType.V3, params.tradeType, params.amountIn, amountOut);
    }

    /// @notice Get all available fee tiers for a V3 router
    function getV3FeeTiers() external view returns (uint24[] memory) {
        return standardFeeTiers;
    }

    /// @notice Add custom fee tier (for forks with different tiers)
    function addCustomFeeTier(uint24 feeTier) external onlyOwner {
        for (uint i = 0; i < standardFeeTiers.length; i++) {
            require(standardFeeTiers[i] != feeTier, "Fee tier already exists");
        }
        standardFeeTiers.push(feeTier);
    }

    /// @notice Get pool info for specific V3 router and tokens
    function getV3PoolInfo(
        address router,
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (
        address pool,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    ) {
        require(v3RouterExists[router], "Router not whitelisted");

        address factory = v3RouterToFactory[router];
        pool = IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee);

        if (pool != address(0)) {
            (sqrtPriceX96, tick, , , , , ) = IUniswapV3Pool(pool).slot0();
            liquidity = IUniswapV3Pool(pool).liquidity();
        }
    }

    /// @notice Withdraw all available tokens from the contract
    function withdrawAllTokens(address[] calldata tokens) external onlyOwner {
        require(tokens.length > 0, "No tokens specified");

        address[] memory withdrawnTokens = new address[](tokens.length);
        uint[] memory withdrawnAmounts = new uint[](tokens.length);
        uint validWithdrawals = 0;

        for (uint i = 0; i < tokens.length; i++) {
            uint balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                require(IERC20(tokens[i]).transfer(owner, balance), "Transfer failed");
                withdrawnTokens[validWithdrawals] = tokens[i];
                withdrawnAmounts[validWithdrawals] = balance;
                validWithdrawals++;

                feeAccumulatedTokens[tokens[i]] = 0;
            }
        }

        address[] memory finalTokens = new address[](validWithdrawals);
        uint[] memory finalAmounts = new uint[](validWithdrawals);

        for (uint i = 0; i < validWithdrawals; i++) {
            finalTokens[i] = withdrawnTokens[i];
            finalAmounts[i] = withdrawnAmounts[i];
        }

        emit AllTokensWithdrawn(owner, finalTokens, finalAmounts);
    }

    /// @notice Withdraw accumulated ETH fees
    function withdrawFeesETH() external onlyOwner {
        uint amount = feeAccumulatedETH;
        require(amount > 0, "No ETH fees");
        feeAccumulatedETH = 0;
        payable(owner).transfer(amount);
        emit FeesWithdrawn(owner, amount);
    }

    /// @notice Withdraw accumulated token fees
    function withdrawFeesToken(address token) external onlyOwner {
        uint amount = feeAccumulatedTokens[token];
        require(amount > 0, "No token fees");
        feeAccumulatedTokens[token] = 0;
        require(IERC20(token).transfer(owner, amount), "Transfer failed");
        emit TokenFeesWithdrawn(owner, token, amount);
    }

    /// @notice Emergency withdrawal functions
    function emergencyWithdrawETH() external onlyOwner {
        uint balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        payable(owner).transfer(balance);
    }

    function emergencyWithdrawToken(address token) external onlyOwner {
        uint balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        require( IERC20(token).transfer(owner, balance), "Transfer failed");
    }

    /// @notice Get router counts
    function getRouterCounts() external view returns (uint v2Count, uint v3Count) {
        return (v2Routers.length, v3Routers.length);
    }

    /// @notice Get all V2 routers
    function getV2Routers() external view returns (address[] memory) {
        return v2Routers;
    }

    /// @notice Get all V3 routers with their factories and quoters
    function getV3Routers() external view returns (
        address[] memory routers,
        address[] memory factories,
        address[] memory quoters
    ) {
        routers = v3Routers;
        factories = new address[](v3Routers.length);
        quoters = new address[](v3Routers.length);

        for (uint i = 0; i < v3Routers.length; i++) {
            factories[i] = v3RouterToFactory[v3Routers[i]];
            quoters[i] = v3RouterToQuoter[v3Routers[i]];
        }
    }

    // Events for better tracking
    event FeesWithdrawn(address indexed owner, uint ethAmount);
    event TokenFeesWithdrawn(address indexed owner, address token, uint amount);
    event AllTokensWithdrawn(address indexed owner, address[] tokens, uint[] amounts);

    // Allow contract to receive ETH
    receive() external payable {}
}
