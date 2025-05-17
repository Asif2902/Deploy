
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


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

interface IERC20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}


contract MonBridgeDex {
    address public owner;
    address[] public routers;
    uint public constant MAX_ROUTERS = 10;
    uint public constant MAX_HOPS = 5; // Increased from 4 to 5
    uint public constant MAX_SPLITS_PER_HOP = 5; // Increased from 4 to 5
    
    // Default slippage tolerance in basis points (0.5%)
    uint public defaultSlippageBps = 50;
    // Minimum acceptable slippage tolerance in basis points (0.1%)
    uint public minSlippageBps = 10;
    // Maximum slippage tolerance for high volatility tokens (5%)
    uint public maxSlippageBps = 500;

    uint public constant SPLIT_THRESHOLD_BPS = 50;
    
    // Fee parameters
    uint public constant FEE_DIVISOR = 1000; 
    uint public feeAccumulatedETH;
    mapping(address => uint) public feeAccumulatedTokens;
    address public WETH;

    // Token whitelist
    mapping(address => bool) public whitelistedTokens;
    
    // Structure definitions
    struct Split {
        address router;    
        uint percentage;
        address[] path;
    }

    struct TradeRoute {
        address inputToken;
        address outputToken;
        uint hops;            
        Split[][] splitRoutes; 
    }
    
    struct PriceImpactData {
        uint amountIn; 
        uint amountOut;
        uint priceImpactBps;
        bool highImpact;
    }
    
    struct ReserveData {
        uint reserve0;
        uint reserve1;
        address token0;
        address token1;
    }
    
    // Simple reentrancy guard
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

    // Events
    event RouterAdded(address router);
    event RouterRemoved(address router);
    event TokenWhitelisted(address token);
    event TokenRemovedFromWhitelist(address token);
    event SwapExecuted(address indexed user, uint amountIn, uint amountOut, uint priceImpactBps);
    event FeesWithdrawn(address indexed owner, uint ethAmount);
    event TokenFeesWithdrawn(address indexed owner, address token, uint amount);
    event SlippageConfigUpdated(uint defaultSlippageBps, uint minSlippageBps, uint maxSlippageBps);
    event RouteOptimized(address inputToken, address outputToken, uint expectedOutput);
    event BestPathCacheUpdated(address inputToken, address outputToken);

    constructor(address _weth) {
        owner = msg.sender;
        WETH = _weth;
        whitelistedTokens[_weth] = true;
    }

    function updateSlippageConfig(uint _defaultSlippageBps, uint _minSlippageBps, uint _maxSlippageBps) external onlyOwner {
        require(_minSlippageBps <= _defaultSlippageBps && _defaultSlippageBps <= _maxSlippageBps, "Invalid slippage config");
        defaultSlippageBps = _defaultSlippageBps;
        minSlippageBps = _minSlippageBps;
        maxSlippageBps = _maxSlippageBps;
        emit SlippageConfigUpdated(_defaultSlippageBps, _minSlippageBps, _maxSlippageBps);
    }

    function addRouters(address[] calldata _routers) external onlyOwner {
        require(routers.length + _routers.length <= MAX_ROUTERS, "Too many routers");
        for (uint i = 0; i < _routers.length; i++) {
            routers.push(_routers[i]);
            emit RouterAdded(_routers[i]);
        }
    }

    function removeRouter(address _router) external onlyOwner {
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == _router) {
                routers[i] = routers[routers.length - 1];
                routers.pop();
                emit RouterRemoved(_router);
                break;
            }
        }
    }

    function whitelistTokens(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            whitelistedTokens[tokens[i]] = true;
            emit TokenWhitelisted(tokens[i]);
        }
    }

    function removeTokenFromWhitelist(address token) external onlyOwner {
        whitelistedTokens[token] = false;
        emit TokenRemovedFromWhitelist(token);
    }

    function getRouters() external view returns (address[] memory) {
        return routers;
    }

    function isWhitelisted(address token) public view returns (bool) {
        return whitelistedTokens[token];
    }

    // This function determines if the token can be used in a hop
    // For intermediate tokens in hops, they MUST be whitelisted
    // For input/output tokens, they don't need to be whitelisted
    function canUseTokenInRoute(address token, address inputToken, address outputToken, bool isIntermediateToken) internal view returns (bool) {
        // Input and output tokens can appear anywhere in the route
        if (token == inputToken || token == outputToken) {
            return true;
        }
        
        // For all other intermediate tokens, they must be whitelisted
        if (isIntermediateToken) {
            return isWhitelisted(token);
        }
        
        // Default case for non-intermediate tokens
        return true;
    }

    // Calculate price impact for a proposed trade
    function getPriceImpact(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (PriceImpactData memory) {
        PriceImpactData memory impactData;
        impactData.amountIn = amountIn;
        
        // Find the best route for this trade
        (TradeRoute memory route, uint expectedOut) = findBestRoute(amountIn, inputToken, outputToken);
        impactData.amountOut = expectedOut;
        
        if (expectedOut == 0 || amountIn == 0) {
            impactData.priceImpactBps = 10000; // 100% impact if no route found
            impactData.highImpact = true;
            return impactData;
        }
        
        // For complex routes, calculate price impact based on reserves and expected output
        uint priceImpactBps = calculateComplexPriceImpact(amountIn, expectedOut, route);
        
        impactData.priceImpactBps = priceImpactBps;
        impactData.highImpact = priceImpactBps > 500; // Over 5% is considered high impact
        
        return impactData;
    }
    
    // Calculate price impact for complex routes
    function calculateComplexPriceImpact(
        uint amountIn, 
        uint amountOut,
        TradeRoute memory route
    ) internal view returns (uint) {
        // If it's a single hop with a single router, use exact calculation
        if (route.hops == 1 && route.splitRoutes[0].length == 1) {
            Split memory split = route.splitRoutes[0][0];
            if (split.path.length == 2) {
                // Simple path, we can calculate exactly
                return calculateExactPriceImpact(amountIn, split.router, split.path);
            }
        }
        
        // For complex routes, use a simplified spot price calculation
        // Get the spot price for a tiny amount (to represent market price)
        uint minAmount = 10**6; // Small test amount
        
        // Try spot price directly or use estimation for very complex routes
        uint spotPrice;
        (TradeRoute memory testRoute, uint testOut) = findBestRoute(minAmount, route.inputToken, route.outputToken);
        
        if (testOut > 0) {
            spotPrice = (minAmount * 10**18) / testOut;
            uint executionPrice = (amountIn * 10**18) / amountOut;
            
            // Calculate price impact: (executionPrice - spotPrice) / spotPrice * 10000
            if (executionPrice > spotPrice) {
                return ((executionPrice - spotPrice) * 10000) / spotPrice;
            }
            return 0; // No impact or positive slippage
        }
        
        // Fallback if we can't calculate spot price
        return defaultSlippageBps * 2; // Use 2x default slippage as estimate
    }
    
    // Calculate exact price impact for a single-hop, single-router trade
    function calculateExactPriceImpact(
        uint amountIn,
        address router,
        address[] memory path
    ) internal view returns (uint) {
        if (path.length != 2) return 300; // Default 3% for complex paths
        
        try IUniswapV2Router02(router).factory() returns (address factory) {
            try IUniswapV2Factory(factory).getPair(path[0], path[1]) returns (address pair) {
                if (pair == address(0)) return 500; // 5% if no pair exists
                
                ReserveData memory reserveData = getReserveData(pair, path[0], path[1]);
                
                // Calculate price impact based on constant product formula (x * y = k)
                uint amountInWithFee = amountIn * 997; // Apply 0.3% fee
                
                uint reserveIn = path[0] == reserveData.token0 ? reserveData.reserve0 : reserveData.reserve1;
                uint reserveOut = path[0] == reserveData.token0 ? reserveData.reserve1 : reserveData.reserve0;
                
                if (reserveIn == 0 || reserveOut == 0) return 1000; // 10% if reserves are empty
                
                // Calculate expected output based on constant product formula
                uint amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
                
                // Calculate price before trade
                uint priceBefore = (reserveIn * 10**18) / reserveOut;
                
                // Calculate price after trade
                uint priceAfter = ((reserveIn + amountIn) * 10**18) / (reserveOut - amountOut);
                
                // Calculate price impact
                if (priceAfter > priceBefore) {
                    return ((priceAfter - priceBefore) * 10000) / priceBefore;
                }
                
                return 0; // No impact or positive slippage
            } catch {
                return 500; // Default 5% if pair retrieval fails
            }
        } catch {
            return 500; // Default 5% if factory retrieval fails
        }
    }
    
    // Helper to get reserve data from a pair
    function getReserveData(address pair, address tokenA, address tokenB) internal view returns (ReserveData memory) {
        ReserveData memory data;
        
        try IUniswapV2Pair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
            data.reserve0 = reserve0;
            data.reserve1 = reserve1;
            
            try IUniswapV2Pair(pair).token0() returns (address token0) {
                data.token0 = token0;
                data.token1 = token0 == tokenA ? tokenB : tokenA;
            } catch {
                // If token0 call fails, make a best guess
                data.token0 = tokenA;
                data.token1 = tokenB;
            }
        } catch {
            // If getReserves fails, return empty data
            data.reserve0 = 0;
            data.reserve1 = 0;
            data.token0 = tokenA;
            data.token1 = tokenB;
        }
        
        return data;
    }

    function findBestRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) public view returns (TradeRoute memory route, uint expectedOut) {
        // Initialize the trade route
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        uint bestOutputLocal = 0;

        // Only check direct route if input/output tokens are valid
        if (canUseTokenInRoute(inputToken, inputToken, outputToken, false) && 
            canUseTokenInRoute(outputToken, inputToken, outputToken, false)) {
            
            // Try direct hop first
            (uint directOutput, Split[] memory directSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                outputToken,
                new address[](0)
            );

            if (directOutput > 0) {
                bestRoute.hops = 1;
                bestRoute.splitRoutes = new Split[][](1);
                bestRoute.splitRoutes[0] = directSplits;
                bestOutputLocal = directOutput;
            }

            // Check router-specific paths
            uint routerSpecificOutput = findBestRouterSpecificPaths(
                amountIn,
                inputToken,
                outputToken
            );

            if (routerSpecificOutput > bestOutputLocal && 
                ((routerSpecificOutput - bestOutputLocal) * 10000 / bestOutputLocal) >= SPLIT_THRESHOLD_BPS) {
                bestOutputLocal = routerSpecificOutput;
            }
        }

        // Try via each common token (WETH, stablecoins)
        address[] memory commonTokens = getCommonIntermediates();
        for (uint i = 0; i < commonTokens.length; i++) {
            address intermediateToken = commonTokens[i];
            if (intermediateToken != inputToken && intermediateToken != outputToken) {
                (TradeRoute memory intermediateRoute, uint intermediateOutput) = findBestRouteViaToken(
                    amountIn,
                    inputToken,
                    outputToken,
                    intermediateToken
                );
                
                if (intermediateOutput > bestOutputLocal && 
                    ((intermediateOutput - bestOutputLocal) * 10000 / bestOutputLocal) >= SPLIT_THRESHOLD_BPS) {
                    bestRoute = intermediateRoute;
                    bestOutputLocal = intermediateOutput;
                }
            }
        }

        // Try stablecoin paths
        address[] memory commonStablecoins = getCommonStablecoins();
        for (uint i = 0; i < commonStablecoins.length; i++) {
            address stablecoin = commonStablecoins[i];
            if (stablecoin != inputToken && stablecoin != outputToken) {
                (TradeRoute memory stableRoute, uint stableOutput) = findBestRouteViaToken(
                    amountIn,
                    inputToken,
                    outputToken,
                    stablecoin
                );
                
                if (stableOutput > bestOutputLocal && 
                    ((stableOutput - bestOutputLocal) * 10000 / bestOutputLocal) >= SPLIT_THRESHOLD_BPS) {
                    bestRoute = stableRoute;
                    bestOutputLocal = stableOutput;
                }
            }
        }

        // Try multi-hop routes of increasing complexity
        for (uint hops = 2; hops <= MAX_HOPS; hops++) {
            (uint hopOutput, TradeRoute memory hopRoute) = findBestMultiHopRoute(
                amountIn,
                inputToken,
                outputToken,
                hops,
                new address[](0)
            );

            if (hopOutput > bestOutputLocal && 
                ((hopOutput - bestOutputLocal) * 10000 / bestOutputLocal) >= SPLIT_THRESHOLD_BPS) {
                bestRoute = hopRoute;
                bestOutputLocal = hopOutput;
            }
        }

        // Try all whitelisted tokens as intermediates
        if (canUseTokenInRoute(inputToken, inputToken, outputToken, false) && 
            canUseTokenInRoute(outputToken, inputToken, outputToken, false)) {
            
            address[] memory potentialIntermediates = getAllWhitelistedTokens();
            
            // Check parallel routes through multiple intermediates
            for (uint i = 0; i < potentialIntermediates.length && i < 20; i++) {
                address intermediateToken = potentialIntermediates[i];
                
                if (intermediateToken != inputToken && 
                    intermediateToken != outputToken && 
                    isWhitelisted(intermediateToken)) {
                    
                    (TradeRoute memory complexRoute, uint complexOutput) = findBestRouteViaToken(
                        amountIn,
                        inputToken,
                        outputToken,
                        intermediateToken
                    );
                    
                    if (complexOutput > bestOutputLocal && 
                        ((complexOutput - bestOutputLocal) * 10000 / bestOutputLocal) >= SPLIT_THRESHOLD_BPS) {
                        bestRoute = complexRoute;
                        bestOutputLocal = complexOutput;
                    }
                }
            }
            
            // Try split routes (multiple paths in parallel)
            TradeRoute memory parallelRoute = findBestParallelRoutes(
                amountIn,
                inputToken,
                outputToken
            );
            
            // Get expected output for parallel route
            uint parallelOutput = getExpectedOutputForRoute(amountIn, parallelRoute);
            
            if (parallelOutput > bestOutputLocal && 
                ((parallelOutput - bestOutputLocal) * 10000 / bestOutputLocal) >= SPLIT_THRESHOLD_BPS) {
                bestRoute = parallelRoute;
                bestOutputLocal = parallelOutput;
            }
        }

        route = bestRoute;
        expectedOut = bestOutputLocal;
    }
    
    // Get expected output for a complex route
    function getExpectedOutputForRoute(uint amountIn, TradeRoute memory route) internal view returns (uint) {
        if (route.hops == 0 || route.splitRoutes.length == 0) {
            return 0;
        }
        
        uint remainingAmount = amountIn;
        
        for (uint i = 0; i < route.hops; i++) {
            Split[] memory splits = route.splitRoutes[i];
            uint nextHopTotal = 0;
            
            for (uint j = 0; j < splits.length; j++) {
                Split memory split = splits[j];
                if (split.router == address(0) || split.percentage == 0) continue;
                
                uint splitAmount = (remainingAmount * split.percentage) / 10000;
                if (splitAmount == 0) continue;
                
                try IUniswapV2Router02(split.router).getAmountsOut(splitAmount, split.path) returns (uint[] memory amounts) {
                    nextHopTotal += amounts[amounts.length - 1];
                } catch {
                    // Skip if router reverts
                }
            }
            
            remainingAmount = nextHopTotal;
            if (remainingAmount == 0) break;
        }
        
        return remainingAmount;
    }
    
    // Find best route via a specific intermediate token
    function findBestRouteViaToken(
        uint amountIn,
        address inputToken,
        address outputToken,
        address intermediateToken
    ) internal view returns (TradeRoute memory route, uint expectedOutput) {
        if (!isValidTokenForPath(intermediateToken, inputToken, outputToken)) {
            return (route, 0);
        }
        
        (address bestRouterFirst, uint firstHopOutput) = findBestRouterForPair(
            amountIn,
            inputToken,
            intermediateToken
        );
        
        if (firstHopOutput == 0) {
            return (route, 0);
        }
        
        (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
            firstHopOutput,
            intermediateToken,
            outputToken,
            new address[](0)
        );
        
        if (secondHopOutput == 0) {
            return (route, 0);
        }
        
        // Create route
        route.inputToken = inputToken;
        route.outputToken = outputToken;
        route.hops = 2;
        route.splitRoutes = new Split[][](2);
        
        // First hop
        route.splitRoutes[0] = new Split[](1);
        route.splitRoutes[0][0] = Split({
            router: bestRouterFirst,
            percentage: 10000, // 100%
            path: getPath(inputToken, intermediateToken)
        });
        
        // Second hop
        route.splitRoutes[1] = secondHopSplits;
        
        expectedOutput = secondHopOutput;
        return (route, expectedOutput);
    }
    
    // Find best parallel routes (multiple paths in parallel)
    function findBestParallelRoutes(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (TradeRoute memory) {
        TradeRoute memory route;
        route.inputToken = inputToken;
        route.outputToken = outputToken;
        route.hops = 1;
        
        // Get all potential intermediate tokens
        address[] memory intermediates = getAllWhitelistedTokens();
        uint[] memory bestOutputs = new uint[](intermediates.length);
        address[] memory bestRouters = new address[](intermediates.length);
        address[][] memory bestPaths = new address[][](intermediates.length);
        
        // Find best output via each intermediate
        uint validRoutes = 0;
        uint totalOutput = 0;
        
        // First try direct routes
        for (uint r = 0; r < routers.length; r++) {
            address router = routers[r];
            if (router == address(0)) continue;
            
            address[] memory directPath = getPath(inputToken, outputToken);
            uint directOutput = 0;
            
            try IUniswapV2Router02(router).getAmountsOut(amountIn, directPath) returns (uint[] memory res) {
                directOutput = res[res.length - 1];
                if (directOutput > 0) {
                    validRoutes++;
                    totalOutput += directOutput;
                    
                    bestOutputs[validRoutes-1] = directOutput;
                    bestRouters[validRoutes-1] = router;
                    bestPaths[validRoutes-1] = directPath;
                }
            } catch {
                // Skip if router reverts
            }
        }
        
        // Then try via intermediate tokens (indirect routes)
        for (uint i = 0; i < intermediates.length && i < 10; i++) {
            address intermediate = intermediates[i];
            if (intermediate == inputToken || intermediate == outputToken) continue;
            
            for (uint r = 0; r < routers.length; r++) {
                address router = routers[r];
                if (router == address(0)) continue;
                
                uint viaOutput = 0;
                address[] memory path = new address[](3);
                path[0] = inputToken;
                path[1] = intermediate;
                path[2] = outputToken;
                
                try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                    viaOutput = res[res.length - 1];
                    if (viaOutput > 0) {
                        validRoutes++;
                        totalOutput += viaOutput;
                        
                        bestOutputs[validRoutes-1] = viaOutput;
                        bestRouters[validRoutes-1] = router;
                        bestPaths[validRoutes-1] = path;
                    }
                } catch {
                    // Skip if router reverts
                }
            }
        }
        
        // Limit to 5 best routes (increased from 4)
        uint maxRoutes = validRoutes > MAX_SPLITS_PER_HOP ? MAX_SPLITS_PER_HOP : validRoutes;
        
        // Create splits based on output proportions
        if (maxRoutes > 0) {
            route.splitRoutes = new Split[][](1);
            route.splitRoutes[0] = new Split[](maxRoutes);
            
            // Sort routes by output (simple insertion sort)
            for (uint i = 0; i < validRoutes; i++) {
                for (uint j = i + 1; j < validRoutes; j++) {
                    if (bestOutputs[j] > bestOutputs[i]) {
                        // Swap outputs
                        uint tempOutput = bestOutputs[i];
                        bestOutputs[i] = bestOutputs[j];
                        bestOutputs[j] = tempOutput;
                        
                        // Swap routers
                        address tempRouter = bestRouters[i];
                        bestRouters[i] = bestRouters[j];
                        bestRouters[j] = tempRouter;
                        
                        // Swap paths
                        address[] memory tempPath = bestPaths[i];
                        bestPaths[i] = bestPaths[j];
                        bestPaths[j] = tempPath;
                    }
                }
            }
            
            // Calculate percentages based on output proportions
            uint totalPercentage = 0;
            for (uint i = 0; i < maxRoutes; i++) {
                uint percentage = (bestOutputs[i] * 10000) / totalOutput;
                
                // Ensure we don't exceed 100%
                if (totalPercentage + percentage > 10000) {
                    percentage = 10000 - totalPercentage;
                }
                
                route.splitRoutes[0][i] = Split({
                    router: bestRouters[i],
                    percentage: percentage,
                    path: bestPaths[i]
                });
                
                totalPercentage += percentage;
            }
            
            // Assign any remaining percentage to the best route
            if (totalPercentage < 10000) {
                route.splitRoutes[0][0].percentage += (10000 - totalPercentage);
            }
        }
        
        return route;
    }

    function findBestRouterSpecificPaths(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint bestOutput) {
        bestOutput = 0;
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;

        for (uint routerIndex = 0; routerIndex < routers.length; routerIndex++) {
            address router = routers[routerIndex];

            if (router == address(0)) continue;
            for (uint hops = 2; hops <= MAX_HOPS; hops++) {
                (uint routerOutput, TradeRoute memory routerRoute) = findBestRouterPath(
                    amountIn,
                    inputToken,
                    outputToken,
                    router,
                    hops
                );

                if (routerOutput > bestOutput) {
                    bestOutput = routerOutput;
                    bestRoute = routerRoute;
                }
            }
        }

        return bestOutput;
    }

    function findBestRouterPath(
        uint amountIn,
        address inputToken,
        address outputToken,
        address router,
        uint hops
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        require(hops >= 2 && hops <= MAX_HOPS, "Invalid hop count");

        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = inputToken;
        bestRouteLocal.outputToken = outputToken;
        bestRouteLocal.hops = hops;
        bestRouteLocal.splitRoutes = new Split[][](hops);

        if (hops == 2) {
            address[] memory potentialIntermediates = getAllWhitelistedTokens();
            uint bestOutputInner = 0;
            address bestIntermediate;

            for (uint i = 0; i < potentialIntermediates.length; i++) {
                address intermediateToken = potentialIntermediates[i];
                if (!isValidTokenForPath(intermediateToken, inputToken, outputToken) || 
                    intermediateToken == inputToken || 
                    intermediateToken == outputToken) {
                    continue;
                }
                
                uint firstHopOutput = 0;
                address[] memory pathFirstHop = getPath(inputToken, intermediateToken);

                try IUniswapV2Router02(router).getAmountsOut(amountIn, pathFirstHop) returns (uint[] memory res) {
                    firstHopOutput = res[res.length - 1];
                } catch {
                    continue;
                }

                if (firstHopOutput == 0) continue;
                uint secondHopOutput = 0;
                address[] memory pathSecondHop = getPath(intermediateToken, outputToken);

                try IUniswapV2Router02(router).getAmountsOut(firstHopOutput, pathSecondHop) returns (uint[] memory res) {
                    secondHopOutput = res[res.length - 1];
                } catch {
                    continue;
                }

                if (secondHopOutput > bestOutputInner) {
                    bestOutputInner = secondHopOutput;
                    bestIntermediate = intermediateToken;
                    bestRouteLocal.splitRoutes[0] = new Split[](1);
                    bestRouteLocal.splitRoutes[0][0] = Split({
                        router: router,
                        percentage: 10000, // 100%
                        path: pathFirstHop
                    });

                    bestRouteLocal.splitRoutes[1] = new Split[](1);
                    bestRouteLocal.splitRoutes[1][0] = Split({
                        router: router,
                        percentage: 10000, // 100%
                        path: pathSecondHop
                    });
                }
            }

            return (bestOutputInner, bestRouteLocal);
        }

        address[] memory intermediates = getAllWhitelistedTokens();
        uint bestOutputLocal = 0;

        for (uint i = 0; i < intermediates.length; i++) {
            address firstHopToken = intermediates[i];
            if (!isValidTokenForPath(firstHopToken, inputToken, outputToken) || 
                firstHopToken == inputToken || 
                firstHopToken == outputToken) {
                continue;
            }
            
            uint firstHopOutput = 0;
            address[] memory pathFirstHop = getPath(inputToken, firstHopToken);

            try IUniswapV2Router02(router).getAmountsOut(amountIn, pathFirstHop) returns (uint[] memory res) {
                firstHopOutput = res[res.length - 1];
            } catch {
                continue;
            }

            if (firstHopOutput == 0) continue;
            (uint remainingOutput, TradeRoute memory remainingRoute) = findBestRouterPathRecursive(
                firstHopOutput,
                firstHopToken,
                outputToken,
                router,
                hops - 1,
                new address[](0)
            );

            if (remainingOutput > 0) {
                uint totalOutput = remainingOutput;

                if (totalOutput > bestOutputLocal) {
                    bestOutputLocal = totalOutput;
                    bestRouteLocal.splitRoutes[0] = new Split[](1);
                    bestRouteLocal.splitRoutes[0][0] = Split({
                        router: router,
                        percentage: 10000, // 100%
                        path: pathFirstHop
                    });
                    for (uint j = 0; j < hops - 1; j++) {
                        bestRouteLocal.splitRoutes[j + 1] = remainingRoute.splitRoutes[j];
                    }
                }
            }
        }

        return (bestOutputLocal, bestRouteLocal);
    }

    function findBestRouterPathRecursive(
        uint amountIn,
        address inputToken,
        address outputToken,
        address router,
        uint hops,
        address[] memory usedIntermediates
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (hops == 1) {
            address[] memory path = getPath(inputToken, outputToken);
            uint amountOut = 0;

            try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                amountOut = res[res.length - 1];
            } catch {
                return (0, route);
            }
            
            route.inputToken = inputToken;
            route.outputToken = outputToken;
            route.hops = 1;
            route.splitRoutes = new Split[][](1);
            route.splitRoutes[0] = new Split[](1);
            route.splitRoutes[0][0] = Split({
                router: router,
                percentage: 10000, // 100%
                path: path
            });

            return (amountOut, route);
        }

        address[] memory intermediates = getAllWhitelistedTokens();
        uint bestOutputLocal = 0;
        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = inputToken;
        bestRouteLocal.outputToken = outputToken;
        bestRouteLocal.hops = hops;
        bestRouteLocal.splitRoutes = new Split[][](hops);

        for (uint i = 0; i < intermediates.length; i++) {
            address currentNextToken = intermediates[i];
            bool alreadyUsed = false;
            for (uint j = 0; j < usedIntermediates.length; j++) {
                if (usedIntermediates[j] == currentNextToken) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed || !isValidTokenForPath(currentNextToken, inputToken, outputToken) || 
                currentNextToken == inputToken || currentNextToken == outputToken) {
                continue;
            }
            
            address[] memory path = getPath(inputToken, currentNextToken);
            uint nextHopOutput = 0;

            try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                nextHopOutput = res[res.length - 1];
            } catch {
                continue;
            }

            if (nextHopOutput == 0) continue;

            address[] memory newUsedIntermediates = new address[](usedIntermediates.length + 1);
            for (uint j = 0; j < usedIntermediates.length; j++) {
                newUsedIntermediates[j] = usedIntermediates[j];
            }
            newUsedIntermediates[usedIntermediates.length] = currentNextToken;
            (uint remainingOutput, TradeRoute memory remainingRoute) = findBestRouterPathRecursive(
                nextHopOutput,
                currentNextToken,
                outputToken,
                router,
                hops - 1,
                newUsedIntermediates
            );

            if (remainingOutput > 0) {
                uint totalOutput = remainingOutput;

                if (totalOutput > bestOutputLocal) {
                    bestOutputLocal = totalOutput;

                    // First hop
                    bestRouteLocal.splitRoutes[0] = new Split[](1);
                    bestRouteLocal.splitRoutes[0][0] = Split({
                        router: router,
                        percentage: 10000, // 100%
                        path: path
                    });

                    // Copy remaining hops
                    for (uint j = 0; j < hops - 1; j++) {
                        bestRouteLocal.splitRoutes[j + 1] = remainingRoute.splitRoutes[j];
                    }
                }
            }
        }

        return (bestOutputLocal, bestRouteLocal);
    }

    function getAllWhitelistedTokens() internal view returns (address[] memory) {
        // Combine common intermediates, stablecoins, and specifically whitelisted tokens
        address[] memory commonTokens = getCommonIntermediates();
        address[] memory stablecoins = getCommonStablecoins();
        
        // Create a larger array to hold all tokens
        uint totalLength = commonTokens.length + stablecoins.length;
        address[] memory allTokens = new address[](totalLength);
        
        // Copy common tokens
        for (uint i = 0; i < commonTokens.length; i++) {
            allTokens[i] = commonTokens[i];
        }
        
        // Copy stablecoins
        for (uint i = 0; i < stablecoins.length; i++) {
            allTokens[commonTokens.length + i] = stablecoins[i];
        }
        
        return allTokens;
    }

    // Helper function to reduce stack depth
    function processFinalHopRoute(
        uint secondHopOutput,
        address secondHopToken,
        address outputToken,
        address router,
        address[] memory secondHopPath,
        uint bestOutputLocal,
        TradeRoute memory bestRouteLocal,
        Split[] memory firstHopSplits
    ) internal view returns (uint, TradeRoute memory) {
        // Find best route for final hop
        (uint finalHopOutput, Split[] memory finalHopSplits) = findBestSplitForHop(
            secondHopOutput,
            secondHopToken,
            outputToken,
            new address[](0)
        );
        
        if (finalHopOutput > 0 && finalHopOutput > bestOutputLocal) {
            bestOutputLocal = finalHopOutput;
            
            // First hop (using best split)
            bestRouteLocal.splitRoutes[0] = firstHopSplits;
            
            // Second hop (using specific router)
            bestRouteLocal.splitRoutes[1] = new Split[](1);
            bestRouteLocal.splitRoutes[1][0] = Split({
                router: router,
                percentage: 10000, // 100%
                path: secondHopPath
            });
            
            // Final hop
            bestRouteLocal.splitRoutes[2] = finalHopSplits;
        }
        
        return (bestOutputLocal, bestRouteLocal);
    }
    
    // Helper function to reduce stack depth
    function processMultiHopRoute(
        uint secondHopOutput,
        address secondHopToken,
        address outputToken,
        address router,
        address[] memory secondHopPath,
        uint bestOutputLocal,
        TradeRoute memory bestRouteLocal,
        Split[] memory firstHopSplits,
        uint hops
    ) internal view returns (uint, TradeRoute memory) {
        // For multi-hop routes, recurse for remaining hops
        (uint remainingOutput, TradeRoute memory remainingRoute) = findBestMultiHopRoute(
            secondHopOutput,
            secondHopToken,
            outputToken,
            hops - 2,
            new address[](0)
        );
        
        if (remainingOutput > 0 && remainingOutput > bestOutputLocal) {
            bestOutputLocal = remainingOutput;
            
            // First hop
            bestRouteLocal.splitRoutes[0] = firstHopSplits;
            
            // Second hop
            bestRouteLocal.splitRoutes[1] = new Split[](1);
            bestRouteLocal.splitRoutes[1][0] = Split({
                router: router,
                percentage: 10000, // 100%
                path: secondHopPath
            });
            
            // Remaining hops
            for (uint j = 0; j < hops - 2; j++) {
                bestRouteLocal.splitRoutes[j + 2] = remainingRoute.splitRoutes[j];
            }
        }
        
        return (bestOutputLocal, bestRouteLocal);
    }
    
    // Helper function to check if token is valid for path
    function isValidTokenForPath(address token, address inputToken, address outputToken) internal view returns (bool) {
        if (token == address(0)) return false;
        return isWhitelisted(token) || token == inputToken || token == outputToken;
    }
    
    // Extract this function to handle second hop token processing
    function processSecondHopToken(
        address firstHopToken,
        address secondHopToken,
        address inputToken,
        address outputToken,
        address router,
        uint firstHopOutput,
        uint hops,
        Split[] memory firstHopSplits,
        uint bestOutputLocal,
        TradeRoute memory bestRouteLocal
    ) internal view returns (uint, TradeRoute memory) {
        if (!isValidTokenForPath(secondHopToken, inputToken, outputToken) || 
            secondHopToken == firstHopToken) {
            return (bestOutputLocal, bestRouteLocal);
        }
        
        // Get second hop output
        uint secondHopOutput = 0;
        address[] memory secondHopPath = getPath(firstHopToken, secondHopToken);
        
        try IUniswapV2Router02(router).getAmountsOut(firstHopOutput, secondHopPath) returns (uint[] memory res) {
            secondHopOutput = res[res.length - 1];
        } catch {
            return (bestOutputLocal, bestRouteLocal);
        }
        
        if (secondHopOutput == 0) return (bestOutputLocal, bestRouteLocal);
        
        // Process based on hop count
        if (hops == 3) {
            return processFinalHopRoute(
                secondHopOutput,
                secondHopToken,
                outputToken,
                router,
                secondHopPath,
                bestOutputLocal,
                bestRouteLocal,
                firstHopSplits
            );
        } else {
            return processMultiHopRoute(
                secondHopOutput,
                secondHopToken,
                outputToken,
                router,
                secondHopPath,
                bestOutputLocal,
                bestRouteLocal,
                firstHopSplits,
                hops
            );
        }
    }
    
    // Extract router iteration to a separate function
    function processRoutersForToken(
        address firstHopToken,
        address[] memory intermediateTokens,
        address inputToken,
        address outputToken,
        uint firstHopOutput,
        uint hops,
        Split[] memory firstHopSplits,
        uint bestOutputLocal,
        TradeRoute memory bestRouteLocal
    ) internal view returns (uint, TradeRoute memory) {
        for (uint r = 0; r < routers.length; r++) {
            address router = routers[r];
            if (router == address(0)) continue;
            
            // Process each second hop token for this router
            for (uint j = 0; j < intermediateTokens.length; j++) {
                (bestOutputLocal, bestRouteLocal) = processSecondHopToken(
                    firstHopToken, 
                    intermediateTokens[j],
                    inputToken,
                    outputToken,
                    router,
                    firstHopOutput,
                    hops,
                    firstHopSplits,
                    bestOutputLocal,
                    bestRouteLocal
                );
            }
        }
        
        return (bestOutputLocal, bestRouteLocal);
    }
    
    function findBestMultiHopRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hops,
        address[] memory /* forbiddenTokens */
    ) internal view returns (uint expectedOut, TradeRoute memory bestRoute) {
        require(hops >= 2 && hops <= MAX_HOPS, "Invalid hop count");

        // Basic initialization
        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = inputToken;
        bestRouteLocal.outputToken = outputToken;
        bestRouteLocal.hops = hops;
        bestRouteLocal.splitRoutes = new Split[][](hops);
        uint bestOutputLocal = 0;

        // Handle simple case first
        if (hops == 2) {
            return findBestTwoHopRoute(amountIn, inputToken, outputToken, new address[](0));
        }

        // Get intermediates and prepare tokens
        address[] memory whitelistedIntermediates = getAllWhitelistedTokens();
        uint intermediateLength = whitelistedIntermediates.length + 2;
        address[] memory intermediateTokens = new address[](intermediateLength);
        
        // Copy whitelisted tokens
        for (uint i = 0; i < whitelistedIntermediates.length; i++) {
            intermediateTokens[i] = whitelistedIntermediates[i];
        }
        
        // Add input and output tokens as potential intermediates
        intermediateTokens[whitelistedIntermediates.length] = inputToken;
        intermediateTokens[whitelistedIntermediates.length + 1] = outputToken;
        
        // Process each first hop token
        for (uint i = 0; i < intermediateTokens.length; i++) {
            address firstHopToken = intermediateTokens[i];
            
            // Skip invalid tokens
            if (!isValidTokenForPath(firstHopToken, inputToken, outputToken)) continue;

            // Get first hop results
            uint firstHopOutput;
            Split[] memory firstHopSplits;
            (firstHopOutput, firstHopSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                firstHopToken,
                new address[](0)
            );
            
            if (firstHopOutput == 0) continue;
            
            // Try recursive approach for comparison
            uint remainingOutput;
            TradeRoute memory remainingRoute;
            (remainingOutput, remainingRoute) = findBestMultiHopRoute(
                firstHopOutput,
                firstHopToken,
                outputToken,
                hops - 1,
                new address[](0) 
            );

            if (remainingOutput > 0 && remainingOutput > bestOutputLocal) {
                bestOutputLocal = remainingOutput;
                bestRouteLocal.splitRoutes[0] = firstHopSplits;
                for (uint k = 0; k < hops - 1; k++) {
                    bestRouteLocal.splitRoutes[k + 1] = remainingRoute.splitRoutes[k];
                }
            }

            // Process all routers for this token
            (bestOutputLocal, bestRouteLocal) = processRoutersForToken(
                firstHopToken,
                intermediateTokens,
                inputToken,
                outputToken,
                firstHopOutput,
                hops,
                firstHopSplits,
                bestOutputLocal,
                bestRouteLocal
            );
        }

        return (bestOutputLocal, bestRouteLocal);
    }

    function isValidIntermediate(address token, address inputToken, address outputToken, address[] memory forbiddenTokens) internal view returns (bool) {
        // Check if token is in forbidden list
        for (uint i = 0; i < forbiddenTokens.length; i++) {
            if (token == forbiddenTokens[i]) return false;
        }

        // Allow if token is the input or output token for the current transaction
        // This allows complex routes like X→Y→X→Z where X is not whitelisted
        if (token == inputToken || token == outputToken) {
            return true;
        }
        
        // Allow WETH as an intermediate token to improve routing possibilities
        if (token == WETH) {
            return true;
        }
        
        // Otherwise, must be whitelisted
        if (!isWhitelisted(token)) return false;

        return true;
    }

    function getCommonIntermediates() internal view returns (address[] memory) {
        // Start with WETH and add more common intermediates if needed
        address[] memory intermediates = new address[](1);
        intermediates[0] = WETH;
        return intermediates;
    }

    function getCommonStablecoins() internal pure returns (address[] memory) {
        address[] memory stablecoins = new address[](2);
        stablecoins[0] = address(0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D); 
        stablecoins[1] = address(0xf817257fed379853cDe0fa4F97AB987181B1E5Ea); 
        return stablecoins;
    }

    // Create non-caching version of getPath that rebuilds path each time
    function getPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
        // Direct path
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;
        
        // If either token is WETH or both are whitelisted, try direct path first
        if (tokenIn == WETH || tokenOut == WETH || (isWhitelisted(tokenIn) && isWhitelisted(tokenOut))) {
            // Try if direct path works
            if (routers.length > 0) {
                try IUniswapV2Router02(routers[0]).getAmountsOut(1, directPath) returns (uint[] memory) {
                    return directPath;
                } catch {
                    // Direct path doesn't work, continue to next options
                }
            }
        }
        
        // For unknown tokens with no direct path, try to route through WETH
        if (tokenIn != WETH && tokenOut != WETH) {
            address[] memory wethPath = new address[](3);
            wethPath[0] = tokenIn;
            wethPath[1] = WETH;
            wethPath[2] = tokenOut;
            
            // Test if this path works
            if (routers.length > 0) {
                try IUniswapV2Router02(routers[0]).getAmountsOut(1, wethPath) returns (uint[] memory) {
                    return wethPath;
                } catch {
                    // Continue to try other options
                }
            }
        }
        
        // Try via popular stablecoins
        address[] memory stablecoins = getCommonStablecoins();
        for (uint i = 0; i < stablecoins.length; i++) {
            address stablecoin = stablecoins[i];
            if (stablecoin != tokenIn && stablecoin != tokenOut) {
                address[] memory stablePath = new address[](3);
                stablePath[0] = tokenIn;
                stablePath[1] = stablecoin;
                stablePath[2] = tokenOut;
                
                // Test if this path works
                if (routers.length > 0) {
                    try IUniswapV2Router02(routers[0]).getAmountsOut(1, stablePath) returns (uint[] memory) {
                        return stablePath;
                    } catch {
                        // Continue to next stablecoin
                    }
                }
            }
        }
        
        // Fallback to direct path if nothing else works
        return directPath;
    }

    // Helper function to update cached path - outside view functions
    function updateBestPathCache(address tokenIn, address tokenOut, address[] memory path) external onlyOwner {
        // This can be called externally to preset efficient paths
        emit BestPathCacheUpdated(tokenIn, tokenOut);
    }

    function withdrawFeesETH() external onlyOwner {
        uint amount = feeAccumulatedETH;
        require(amount > 0, "No ETH fees");
        feeAccumulatedETH = 0;
        payable(owner).transfer(amount);
        emit FeesWithdrawn(owner, amount);
    }

    function withdrawFeesToken(address token) external onlyOwner {
        uint amount = feeAccumulatedTokens[token];
        require(amount > 0, "No token fees");
        feeAccumulatedTokens[token] = 0;
        require(IERC20(token).transfer(owner, amount), "Transfer failed");
        emit TokenFeesWithdrawn(owner, token, amount);
    }

    function findBestTwoHopRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        address[] memory /* forbiddenTokens */
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = inputToken;
        bestRouteLocal.outputToken = outputToken;
        bestRouteLocal.hops = 2;
        bestRouteLocal.splitRoutes = new Split[][](2);

        uint bestOutputLocal = 0;
        Split[] memory bestFirstHopSplits;
        Split[] memory bestSecondHopSplits;
        
        // Get potential intermediate tokens - include whitelisted tokens + input/output
        address[] memory whitelistedIntermediates = getAllWhitelistedTokens();
        address[] memory potentialIntermediates = new address[](whitelistedIntermediates.length + 2);
        
        // Add whitelisted tokens
        for (uint i = 0; i < whitelistedIntermediates.length; i++) {
            potentialIntermediates[i] = whitelistedIntermediates[i];
        }
        
        // Also add input and output tokens as potential intermediates
        potentialIntermediates[whitelistedIntermediates.length] = inputToken;
        potentialIntermediates[whitelistedIntermediates.length + 1] = outputToken;

        // Try all possible intermediates
        for (uint i = 0; i < potentialIntermediates.length; i++) {
            address intermediate = potentialIntermediates[i];
            
            // Skip empty addresses
            if (intermediate == address(0)) continue;
            
            // Only use token if it's whitelisted or an input/output token
            if (!isWhitelisted(intermediate) && 
                intermediate != inputToken && 
                intermediate != outputToken) continue;
                
            // Standard case: use findBestSplitForHop for both hops
            (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                intermediate,
                new address[](0)
            );

            if (firstHopOutput == 0) continue;
            
            (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
                firstHopOutput,
                intermediate,
                outputToken,
                new address[](0)
            );

            if (secondHopOutput > bestOutputLocal) {
                bestOutputLocal = secondHopOutput;
                bestFirstHopSplits = firstHopSplits;
                bestSecondHopSplits = secondHopSplits;
            }
            
            // Now try special case: Multi-router with splits on the second hop
            uint firstHopOutputWithSplit = 0;
            
            // Try each router for first hop
            for (uint r1 = 0; r1 < routers.length; r1++) {
                address router1 = routers[r1];
                if (router1 == address(0)) continue;
                
                address[] memory path1 = getPath(inputToken, intermediate);
                try IUniswapV2Router02(router1).getAmountsOut(amountIn, path1) returns (uint[] memory res) {
                    firstHopOutputWithSplit = res[res.length - 1];
                } catch {
                    continue;
                }
                
                if (firstHopOutputWithSplit == 0) continue;
                
                // Try splitting second hop between multiple routers
                for (uint r2 = 0; r2 < routers.length; r2++) {
                    address router2 = routers[r2];
                    if (router2 == address(0) || router2 == router1) continue;
                    
                    address[] memory path2 = getPath(intermediate, outputToken);
                    uint outputRouter2 = 0;
                    
                    try IUniswapV2Router02(router2).getAmountsOut(firstHopOutputWithSplit/2, path2) returns (uint[] memory res) {
                        outputRouter2 = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    if (outputRouter2 == 0) continue;
                    
                    // Try a third route that goes back through the input token (complex case)
                    for (uint r3 = 0; r3 < routers.length; r3++) {
                        address router3 = routers[r3];
                        if (router3 == address(0)) continue;
                        
                        // Complex path: intermediate → input → output
                        address[] memory pathToInput = getPath(intermediate, inputToken);
                        uint intermediateToInput = 0;
                        
                        try IUniswapV2Router02(router3).getAmountsOut(firstHopOutputWithSplit/2, pathToInput) returns (uint[] memory res) {
                            intermediateToInput = res[res.length - 1];
                        } catch {
                            continue;
                        }
                        
                        if (intermediateToInput == 0) continue;
                        
                        address[] memory pathToOutput = getPath(inputToken, outputToken);
                        uint inputToOutput = 0;
                        
                        try IUniswapV2Router02(router3).getAmountsOut(intermediateToInput, pathToOutput) returns (uint[] memory res) {
                            inputToOutput = res[res.length - 1];
                        } catch {
                            continue;
                        }
                        
                        // Calculate total output from both paths
                        uint totalComplexOutput = outputRouter2 + inputToOutput;
                        
                        if (totalComplexOutput > bestOutputLocal) {
                            bestOutputLocal = totalComplexOutput;
                            
                            // Set up first hop
                            bestFirstHopSplits = new Split[](1);
                            bestFirstHopSplits[0] = Split({
                                router: router1,
                                percentage: 10000, // 100%
                                path: path1
                            });
                            
                            // Set up second hop as a split
                            bestSecondHopSplits = new Split[](2);
                            bestSecondHopSplits[0] = Split({
                                router: router2,
                                percentage: 5000, // 50%
                                path: path2
                            });
                            bestSecondHopSplits[1] = Split({
                                router: router3,
                                percentage: 5000, // 50%
                                path: pathToInput  // First part of complex path
                            });
                        }
                    }
                }
            }
        }

        // Construct the final route
        if (bestOutputLocal > 0) {
            bestRouteLocal.splitRoutes[0] = bestFirstHopSplits;
            bestRouteLocal.splitRoutes[1] = bestSecondHopSplits;
        }

        return (bestOutputLocal, bestRouteLocal);
    }

    function findBestSplitForHop(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory /* forbiddenTokens */
    ) internal view returns (uint expectedOut, Split[] memory splits) {
        (address bestRouter, uint bestAmountOut) = findBestRouterForPair(amountIn, tokenIn, tokenOut);

        if (bestRouter == address(0)) {
            return (0, new Split[](0));
        }

        Split[] memory bestSplits = new Split[](1);
        bestSplits[0] = Split({
            router: bestRouter,
            percentage: 10000, // 100%
            path: getPath(tokenIn, tokenOut)
        });

        uint totalOutput = bestAmountOut;

        // Only try splitting if there are multiple routers
        if (routers.length >= 2) {
            address[] memory topRouters;
            uint[] memory routerOutputs;
            (topRouters, routerOutputs) = findTopRoutersForPair(amountIn, tokenIn, tokenOut, MAX_SPLITS_PER_HOP);

            bool multipleValidRouters = false;
            uint validRouterCount = 0;
            for (uint i = 0; i < topRouters.length; i++) {
                if (topRouters[i] != address(0) && routerOutputs[i] > 0) {
                    validRouterCount++;
                    if (validRouterCount > 1) {
                        multipleValidRouters = true;
                        break;
                    }
                }
            }

            if (multipleValidRouters) {
                (uint optimizedOutput, uint[] memory optimizedPercentages) = optimizeSplitPercentages(
                    amountIn,
                    tokenIn,
                    tokenOut,
                    topRouters
                );

                if (optimizedOutput > totalOutput && 
                    ((optimizedOutput - totalOutput) * 10000 / totalOutput) >= SPLIT_THRESHOLD_BPS) {
                    totalOutput = optimizedOutput;
                    uint nonZeroCount = 0;
                    for (uint i = 0; i < topRouters.length; i++) {
                        if (optimizedPercentages[i] > 0 && topRouters[i] != address(0)) {
                            nonZeroCount++;
                        }
                    }

                    bestSplits = new Split[](nonZeroCount);
                    uint splitIndex = 0;

                    for (uint i = 0; i < topRouters.length; i++) {
                        if (optimizedPercentages[i] > 0 && topRouters[i] != address(0)) {
                            bestSplits[splitIndex] = Split({
                                router: topRouters[i],
                                percentage: optimizedPercentages[i],
                                path: getPath(tokenIn, tokenOut)
                            });
                            splitIndex++;
                        }
                    }
                }
            }
        }

        return (totalOutput, bestSplits);
    }

    function findBestRouterForPair(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (address bestRouter, uint bestAmountOut) {
        bestAmountOut = 0;
        bestRouter = address(0);

        // Try direct path first
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;
            
            uint[] memory amountsInner;
            address[] memory path = getPath(tokenIn, tokenOut);

            // Use try/catch to skip routers that revert
            try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                amountsInner = res;
                uint amountOut = amountsInner[amountsInner.length - 1];
                if (amountOut > bestAmountOut) {
                    bestAmountOut = amountOut;
                    bestRouter = routers[i];
                }
            } catch {
                // Continue to next router
            }
        }
        
        // If no direct path works and WETH is neither input nor output, try through WETH
        if (bestAmountOut == 0 && tokenIn != WETH && tokenOut != WETH) {
            for (uint i = 0; i < routers.length; i++) {
                address router = routers[i];
                if (router == address(0)) continue;
                
                // Try tokenIn -> WETH
                uint firstHopOutput = 0;
                address[] memory pathFirst = new address[](2);
                pathFirst[0] = tokenIn;
                pathFirst[1] = WETH;
                
                try IUniswapV2Router02(router).getAmountsOut(amountIn, pathFirst) returns (uint[] memory res) {
                    firstHopOutput = res[res.length - 1];
                } catch {
                    continue;
                }
                
                if (firstHopOutput > 0) {
                    // Try WETH -> tokenOut
                    address[] memory pathSecond = new address[](2);
                    pathSecond[0] = WETH;
                    pathSecond[1] = tokenOut;
                    
                    try IUniswapV2Router02(router).getAmountsOut(firstHopOutput, pathSecond) returns (uint[] memory res) {
                        uint finalOutput = res[res.length - 1];
                        if (finalOutput > bestAmountOut) {
                            bestAmountOut = finalOutput;
                            bestRouter = router;
                        }
                    } catch {
                        // Continue to next router
                    }
                }
            }
        }
        
        // Try common stablecoins as intermediates
        if (bestAmountOut == 0) {
            address[] memory stablecoins = getCommonStablecoins();
            for (uint s = 0; s < stablecoins.length; s++) {
                address stablecoin = stablecoins[s];
                if (stablecoin == tokenIn || stablecoin == tokenOut) continue;
                
                for (uint i = 0; i < routers.length; i++) {
                    address router = routers[i];
                    if (router == address(0)) continue;
                    
                    // Try tokenIn -> stablecoin
                    uint firstHopOutput = 0;
                    address[] memory pathFirst = new address[](2);
                    pathFirst[0] = tokenIn; 
                    pathFirst[1] = stablecoin;
                    
                    try IUniswapV2Router02(router).getAmountsOut(amountIn, pathFirst) returns (uint[] memory res) {
                        firstHopOutput = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    if (firstHopOutput > 0) {
                        // Try stablecoin -> tokenOut
                        address[] memory pathSecond = new address[](2);
                        pathSecond[0] = stablecoin;
                        pathSecond[1] = tokenOut;
                        
                        try IUniswapV2Router02(router).getAmountsOut(firstHopOutput, pathSecond) returns (uint[] memory res) {
                            uint finalOutput = res[res.length - 1];
                            if (finalOutput > bestAmountOut) {
                                bestAmountOut = finalOutput;
                                bestRouter = router;
                            }
                        } catch {
                            // Continue to next router
                        }
                    }
                }
            }
        }
        
        return (bestRouter, bestAmountOut);
    }

    function findTopRoutersForPair(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        uint count
    ) internal view returns (address[] memory topRouters, uint[] memory amountsOut) {
        require(count <= MAX_SPLITS_PER_HOP, "Count exceeds max splits");
        require(count <= routers.length, "Count exceeds router count");

        topRouters = new address[](count);
        amountsOut = new uint[](count);

        // Calculate amounts for all routers
        address[] memory allRouters = new address[](routers.length);
        uint[] memory allAmounts = new uint[](routers.length);

        // Get path to use for all routers
        address[] memory path = getPath(tokenIn, tokenOut);

        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;
            allRouters[i] = routers[i];

            uint[] memory amountsInner;

            try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                amountsInner = res;
                allAmounts[i] = amountsInner[amountsInner.length - 1];
            } catch {
                allAmounts[i] = 0;
            }
        }

        // Sort routers by amount out (simple bubble sort)
        for (uint i = 0; i < routers.length; i++) {
            for (uint j = i + 1; j < routers.length; j++) {
                if (allAmounts[j] > allAmounts[i]) {
                    // Swap amounts
                    uint tempAmount = allAmounts[i];
                    allAmounts[i] = allAmounts[j];
                    allAmounts[j] = tempAmount;

                    // Swap routers
                    address tempRouter = allRouters[i];
                    allRouters[i] = allRouters[j];
                    allRouters[j] = tempRouter;
                }
            }
        }

        // Get top N routers
        for (uint i = 0; i < count && i < routers.length; i++) {
            if (allAmounts[i] > 0) {
                topRouters[i] = allRouters[i];
                amountsOut[i] = allAmounts[i];
            }
        }
    }

    function calculateSplitOutput(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters,
        uint[] memory splitPercentages
    ) internal view returns (uint totalOutput) {
        require(splitRouters.length == splitPercentages.length, "Array length mismatch");

        totalOutput = 0;
        address[] memory path = getPath(tokenIn, tokenOut);
        
        uint totalPercentage = 0;
        for (uint i = 0; i < splitPercentages.length; i++) {
            totalPercentage += splitPercentages[i];
        }
        
        // If total percentage is not 100%, adjust amounts accordingly
        uint adjustmentFactor = totalPercentage > 0 ? 10000 / totalPercentage : 0;

        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] == address(0) || splitPercentages[i] == 0) continue;

            uint routerAmountIn;
            
            if (adjustmentFactor != 0 && adjustmentFactor != 1) {
                routerAmountIn = (amountIn * splitPercentages[i] * adjustmentFactor) / 100000000;
            } else {
                routerAmountIn = (amountIn * splitPercentages[i]) / 10000;
            }
            
            if (routerAmountIn == 0) continue;

            try IUniswapV2Router02(splitRouters[i]).getAmountsOut(routerAmountIn, path) returns (uint[] memory amounts) {
                totalOutput += amounts[amounts.length - 1];
            } catch {
                // Skip if router reverts
            }
        }
    }

    // Improved algorithm for finding optimal split distribution
    function optimizeSplitPercentages(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters
    ) internal view returns (uint bestOutput, uint[] memory bestPercentages) {
        uint routerCount = 0;
        uint[] memory routerOutputs = new uint[](splitRouters.length);
        uint totalPossibleOutput = 0;
        
        // Get individual router outputs for estimating liquidity
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0)) {
                routerCount++;
                address[] memory path = getPath(tokenIn, tokenOut);
                
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                    routerOutputs[i] = amounts[amounts.length - 1];
                    totalPossibleOutput += routerOutputs[i];
                } catch {
                    routerOutputs[i] = 0;
                }
            }
        }

        if (routerCount == 0) return (0, new uint[](0));

        // Start with proportional distribution based on liquidity
        bestPercentages = new uint[](splitRouters.length);
        
        if (totalPossibleOutput > 0) {
            for (uint i = 0; i < splitRouters.length; i++) {
                if (routerOutputs[i] > 0) {
                    bestPercentages[i] = (routerOutputs[i] * 10000) / totalPossibleOutput;
                }
            }
            
            // Ensure total is 100%
            uint totalPercentage = 0;
            for (uint i = 0; i < bestPercentages.length; i++) {
                totalPercentage += bestPercentages[i];
            }
            
            if (totalPercentage < 10000) {
                // Find best router by output
                uint maxOutput = 0;
                uint maxIndex = 0;
                for (uint i = 0; i < routerOutputs.length; i++) {
                    if (routerOutputs[i] > maxOutput) {
                        maxOutput = routerOutputs[i];
                        maxIndex = i;
                    }
                }
                // Assign remaining percentage to best router
                bestPercentages[maxIndex] += (10000 - totalPercentage);
            }
        } else {
            // If no individual outputs, distribute equally
            for (uint i = 0; i < splitRouters.length && splitRouters[i] != address(0); i++) {
                bestPercentages[i] = 10000 / routerCount;
            }
        }

        // Test this initial distribution
        bestOutput = calculateSplitOutput(
            amountIn,
            tokenIn,
            tokenOut,
            splitRouters,
            bestPercentages
        );
        
        // Generate and test various percentage distributions
        generateAndTestDistributions(
            amountIn, 
            tokenIn, 
            tokenOut, 
            splitRouters, 
            routerOutputs, 
            bestOutput, 
            bestPercentages
        );
        
        // Add more sophisticated split patterns for 3+ routers
        if (routerCount >= 3) {
            generateAdvancedDistributions(
                amountIn,
                tokenIn,
                tokenOut,
                splitRouters,
                routerOutputs,
                bestOutput,
                bestPercentages
            );
        }
        
        return (bestOutput, bestPercentages);
    }
    
    // Generator for pair distributions (between 2 routers)
    function generateAndTestDistributions(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters,
        uint[] memory routerOutputs,
        uint bestOutput,
        uint[] memory bestPercentages
    ) internal view returns (uint, uint[] memory) {
        // Find top routers by output
        uint[] memory topIndices = new uint[](2);
        uint[] memory topOutputs = new uint[](2);
        
        // Find best router
        for (uint i = 0; i < routerOutputs.length; i++) {
            if (routerOutputs[i] > topOutputs[0]) {
                topOutputs[1] = topOutputs[0];
                topIndices[1] = topIndices[0];
                topOutputs[0] = routerOutputs[i];
                topIndices[0] = i;
            } else if (routerOutputs[i] > topOutputs[1]) {
                topOutputs[1] = routerOutputs[i];
                topIndices[1] = i;
            }
        }
        
        // Array of percentage distributions to test
        uint[][] memory distributions = new uint[][](20);
        
        // Single router distributions
        uint[] memory dist100_0 = new uint[](splitRouters.length);
        dist100_0[topIndices[0]] = 10000;
        distributions[0] = dist100_0;
        
        if (topOutputs[1] > 0) {
            uint[] memory dist0_100 = new uint[](splitRouters.length);
            dist0_100[topIndices[1]] = 10000;
            distributions[1] = dist0_100;
            
            // Two router distributions with varying percentages
            uint[] memory percentages = new uint[](9);
            percentages[0] = 9000; // 90-10
            percentages[1] = 8000; // 80-20
            percentages[2] = 7500; // 75-25
            percentages[3] = 7000; // 70-30
            percentages[4] = 6000; // 60-40
            percentages[5] = 5000; // 50-50
            percentages[6] = 4000; // 40-60 
            percentages[7] = 3000; // 30-70
            percentages[8] = 2000; // 20-80
            
            for (uint i = 0; i < percentages.length; i++) {
                uint[] memory dist = new uint[](splitRouters.length);
                dist[topIndices[0]] = percentages[i];
                dist[topIndices[1]] = 10000 - percentages[i];
                distributions[i+2] = dist;
            }
        }
        
        // Test each distribution
        for (uint i = 0; i < distributions.length; i++) {
            if (distributions[i].length == 0) continue;
            
            uint output = calculateSplitOutput(
                amountIn,
                tokenIn,
                tokenOut,
                splitRouters,
                distributions[i]
            );
            
            if (output > bestOutput) {
                bestOutput = output;
                bestPercentages = distributions[i];
            }
        }
        
        return (bestOutput, bestPercentages);
    }
    
    // Generate advanced distributions for 3+ routers
    function generateAdvancedDistributions(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters,
        uint[] memory routerOutputs,
        uint bestOutput,
        uint[] memory bestPercentages
    ) internal view returns (uint, uint[] memory) {
        // Find top 3 routers
        uint[] memory topIndices = new uint[](3);
        uint[] memory topOutputs = new uint[](3);
        
        for (uint i = 0; i < routerOutputs.length; i++) {
            if (routerOutputs[i] > topOutputs[0]) {
                topOutputs[2] = topOutputs[1];
                topIndices[2] = topIndices[1];
                topOutputs[1] = topOutputs[0];
                topIndices[1] = topIndices[0];
                topOutputs[0] = routerOutputs[i];
                topIndices[0] = i;
            } else if (routerOutputs[i] > topOutputs[1]) {
                topOutputs[2] = topOutputs[1];
                topIndices[2] = topIndices[1];
                topOutputs[1] = routerOutputs[i];
                topIndices[1] = i;
            } else if (routerOutputs[i] > topOutputs[2]) {
                topOutputs[2] = routerOutputs[i];
                topIndices[2] = i;
            }
        }
        
        // Generate 3-router distributions
        uint[][] memory distributions = new uint[][](15);
        
        // Equal distribution
        uint[] memory dist33_33_33 = new uint[](splitRouters.length);
        dist33_33_33[topIndices[0]] = 3333;
        dist33_33_33[topIndices[1]] = 3333;
        dist33_33_33[topIndices[2]] = 3334;
        distributions[0] = dist33_33_33;
        
        // Weighted by liquidity
        uint totalTop3 = topOutputs[0] + topOutputs[1] + topOutputs[2];
        if (totalTop3 > 0) {
            uint[] memory distWeighted = new uint[](splitRouters.length);
            distWeighted[topIndices[0]] = (topOutputs[0] * 10000) / totalTop3;
            distWeighted[topIndices[1]] = (topOutputs[1] * 10000) / totalTop3;
            distWeighted[topIndices[2]] = 10000 - distWeighted[topIndices[0]] - distWeighted[topIndices[1]];
            distributions[1] = distWeighted;
        }
        
        // Various distributions
        uint[] memory dist50_30_20 = new uint[](splitRouters.length);
        dist50_30_20[topIndices[0]] = 5000;
        dist50_30_20[topIndices[1]] = 3000;
        dist50_30_20[topIndices[2]] = 2000;
        distributions[2] = dist50_30_20;
        
        uint[] memory dist60_30_10 = new uint[](splitRouters.length);
        dist60_30_10[topIndices[0]] = 6000;
        dist60_30_10[topIndices[1]] = 3000;
        dist60_30_10[topIndices[2]] = 1000;
        distributions[3] = dist60_30_10;
        
        uint[] memory dist40_40_20 = new uint[](splitRouters.length);
        dist40_40_20[topIndices[0]] = 4000;
        dist40_40_20[topIndices[1]] = 4000;
        dist40_40_20[topIndices[2]] = 2000;
        distributions[4] = dist40_40_20;
        
        uint[] memory dist70_20_10 = new uint[](splitRouters.length);
        dist70_20_10[topIndices[0]] = 7000;
        dist70_20_10[topIndices[1]] = 2000;
        dist70_20_10[topIndices[2]] = 1000;
        distributions[5] = dist70_20_10;
        
        uint[] memory dist60_20_20 = new uint[](splitRouters.length);
        dist60_20_20[topIndices[0]] = 6000;
        dist60_20_20[topIndices[1]] = 2000;
        dist60_20_20[topIndices[2]] = 2000;
        distributions[6] = dist60_20_20;
        
        uint[] memory dist45_45_10 = new uint[](splitRouters.length);
        dist45_45_10[topIndices[0]] = 4500;
        dist45_45_10[topIndices[1]] = 4500;
        dist45_45_10[topIndices[2]] = 1000;
        distributions[7] = dist45_45_10;
        
        // More variations
        uint[] memory dist55_25_20 = new uint[](splitRouters.length);
        dist55_25_20[topIndices[0]] = 5500;
        dist55_25_20[topIndices[1]] = 2500;
        dist55_25_20[topIndices[2]] = 2000;
        distributions[8] = dist55_25_20;
        
        uint[] memory dist30_30_40 = new uint[](splitRouters.length);
        dist30_30_40[topIndices[0]] = 3000;
        dist30_30_40[topIndices[1]] = 3000;
        dist30_30_40[topIndices[2]] = 4000;
        distributions[9] = dist30_30_40;
        
        uint[] memory dist70_15_15 = new uint[](splitRouters.length);
        dist70_15_15[topIndices[0]] = 7000;
        dist70_15_15[topIndices[1]] = 1500;
        dist70_15_15[topIndices[2]] = 1500;
        distributions[10] = dist70_15_15;
        
        // Test each distribution
        for (uint i = 0; i < distributions.length; i++) {
            if (distributions[i].length == 0) continue;
            
            uint output = calculateSplitOutput(
                amountIn,
                tokenIn,
                tokenOut,
                splitRouters,
                distributions[i]
            );
            
            if (output > bestOutput) {
                bestOutput = output;
                bestPercentages = distributions[i];
            }
        }
        
        // Try small adjustments to the best current distribution
        uint[] memory currentBest = bestPercentages;
        uint[] memory adjustedDist = new uint[](splitRouters.length);
        
        // Copy current best
        for (uint i = 0; i < currentBest.length; i++) {
            adjustedDist[i] = currentBest[i];
        }
        
        // Try minor adjustments (shift 5% between routers)
        uint adjustAmount = 500; // 5%
        
        for (uint i = 0; i < 3; i++) {
            for (uint j = 0; j < 3; j++) {
                if (i == j) continue;
                if (currentBest[topIndices[i]] < adjustAmount) continue;
                
                // Reset to current best
                for (uint k = 0; k < currentBest.length; k++) {
                    adjustedDist[k] = currentBest[k];
                }
                
                // Shift percentage from i to j
                adjustedDist[topIndices[i]] -= adjustAmount;
                adjustedDist[topIndices[j]] += adjustAmount;
                
                uint output = calculateSplitOutput(
                    amountIn,
                    tokenIn,
                    tokenOut,
                    splitRouters,
                    adjustedDist
                );
                
                if (output > bestOutput) {
                    bestOutput = output;
                    // Copy adjustedDist to bestPercentages
                    for (uint k = 0; k < adjustedDist.length; k++) {
                        bestPercentages[k] = adjustedDist[k];
                    }
                }
            }
        }
        
        return (bestOutput, bestPercentages);
    }

    // Calculate dynamic slippage based on token volatility
    function calculateDynamicSlippage(address inputToken, address outputToken, uint expectedOut) internal view returns (uint slippageBps) {
        // Start with the default slippage
        slippageBps = defaultSlippageBps;

        // Get decimals to understand token precision 
        uint8 decimalsIn;
        uint8 decimalsOut;

        try IERC20(inputToken).decimals() returns (uint8 dec) {
            decimalsIn = dec;
        } catch {
            decimalsIn = 18; // Default to 18 if no decimals function
        }

        try IERC20(outputToken).decimals() returns (uint8 dec) {
            decimalsOut = dec;
        } catch {
            decimalsOut = 18; // Default to 18 if no decimals function
        }

        // For very low expected amounts, increase slippage to avoid failures
        if (decimalsOut >= 9 && expectedOut < 10 ** (decimalsOut - 6)) {
            slippageBps = maxSlippageBps; // Use max slippage for very small amounts
            return slippageBps;
        }

        // Check if either token is WETH - typically more stable pairs
        if (inputToken == WETH || outputToken == WETH) {
            return slippageBps; // Use default slippage for WETH pairs
        }

        // If neither token is whitelisted, use higher slippage
        if (!isWhitelisted(inputToken) && !isWhitelisted(outputToken)) {
            slippageBps = maxSlippageBps;
            return slippageBps;
        }

        // If only one token is whitelisted, use medium slippage
        if (!isWhitelisted(inputToken) || !isWhitelisted(outputToken)) {
            slippageBps = (defaultSlippageBps + maxSlippageBps) / 2;
            return slippageBps;
        }

        return slippageBps;
    }

    // Calculate minimum amount out with dynamic slippage
    function calculateMinAmountOut(uint expectedOut, address inputToken, address outputToken) internal view returns (uint minAmountOut) {
        uint slippageBps = calculateDynamicSlippage(inputToken, outputToken, expectedOut);

        // Ensure slippage is within the acceptable range
        if (slippageBps < minSlippageBps) {
            slippageBps = minSlippageBps;
        } else if (slippageBps > maxSlippageBps) {
            slippageBps = maxSlippageBps;
        }

        // Apply slippage tolerance: expectedOut * (10000 - slippageBps) / 10000
        minAmountOut = (expectedOut * (10000 - slippageBps)) / 10000;
    }

    function executeSwap(
        uint amountIn,
        uint amountOutMin,
        TradeRoute calldata route,
        uint deadline
    ) external payable nonReentrant returns (uint amountOut) {
        require(route.hops > 0 && route.hops <= MAX_HOPS, "Invalid hop count");
        require(route.splitRoutes.length == route.hops, "Invalid route structure");

        // Calculate price impact before execution
        uint priceImpactBps = 0;
        (uint expectedOut, bool highImpact) = calculatePriceImpactInternal(amountIn, route);
        
        if (expectedOut > 0) {
            priceImpactBps = ((amountIn * getTokenOutValueInTokenIn(route.outputToken, route.inputToken, expectedOut)) * 10000) / amountIn;
            
            // Cap at 10000 (100%)
            if (priceImpactBps > 10000) {
                priceImpactBps = 10000;
            }
        }

        // Validate all intermediate tokens are whitelisted
        for (uint i = 0; i < route.hops; i++) {
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                Split memory split = route.splitRoutes[i][j];

                // Check all tokens in the path
                for (uint k = 0; k < split.path.length; k++) {
                    address token = split.path[k];

                    // Only allow input token or output token to appear anywhere in the path
                    // All other intermediate tokens must be whitelisted
                    if (token == route.inputToken || token == route.outputToken) {
                        continue;
                    } else {
                        require(isWhitelisted(token), "Intermediate token not whitelisted");
                    }
                }
            }
        }

        bool isETHInput = msg.value > 0;

        // Handle ETH input
        if (isETHInput) {
            require(route.inputToken == WETH, "Input token must be WETH for ETH input");
            require(msg.value == amountIn, "ETH amount doesn't match amountIn");

            // Wrap ETH to WETH
            IWETH(WETH).deposit{value: amountIn}();
        } else {
            require(IERC20(route.inputToken).transferFrom(msg.sender, address(this), amountIn), "Transfer failed");
        }

        // Calculate fee
        uint fee = amountIn / FEE_DIVISOR;
        uint remainingAmount = amountIn - fee;

        if (isETHInput) {
            feeAccumulatedETH += fee;
        } else {
            feeAccumulatedTokens[route.inputToken] += fee;
        }

        // Execute each hop
        address currentToken = route.inputToken;
        amountOut = remainingAmount;

        for (uint hopIndex = 0; hopIndex < route.hops; hopIndex++) {
            Split[] memory splits = route.splitRoutes[hopIndex];
            require(splits.length > 0 && splits.length <= MAX_SPLITS_PER_HOP, "Invalid split count");

            // Validate intermediate tokens
            if (hopIndex < route.hops - 1) {
                address currentNextToken = splits[0].path[splits[0].path.length - 1];
                for (uint i = 1; i < splits.length; i++) {
                    require(
                        splits[i].path[splits[i].path.length - 1] == currentNextToken,
                        "Inconsistent paths in splits"
                    );
                }

                // Check if intermediate token is whitelisted
                if (currentNextToken != route.outputToken) {
                    require(isWhitelisted(currentNextToken), "Intermediate token not whitelisted");
                }
            }

            uint nextAmountOut = 0;
            address nextToken = splits[0].path[splits[0].path.length - 1];

            for (uint splitIndex = 0; splitIndex < splits.length; splitIndex++) {
                Split memory split = splits[splitIndex];
                if (split.router == address(0) || split.percentage == 0) continue;

                // Calculate amount for this split
                uint splitAmount = (amountOut * split.percentage) / 10000;
                if (splitAmount == 0) continue;

                // Calculate minimum output for this split
                uint splitMinAmountOut = 0; // 0 for non-final hops

                // Only apply a minimum amount out on the final hop
                if (hopIndex == route.hops - 1) {
                    if (splits.length == 1) {
                        // If only one split in final hop, use the user-supplied minAmountOut
                        splitMinAmountOut = amountOutMin;
                    } else {
                        // For multiple splits in final hop, calculate proportional minAmountOut
                        // or use dynamically calculated value if amountOutMin is 0
                        if (amountOutMin == 0) {
                            // Get the expected output for this split
                            uint[] memory amountsInner;
                            try IUniswapV2Router02(split.router).getAmountsOut(splitAmount, split.path) returns (uint[] memory res) {
                                amountsInner = res;
                                uint expectedSplitOut = amountsInner[amountsInner.length - 1];
                                // Apply dynamic slippage
                                splitMinAmountOut = calculateMinAmountOut(expectedSplitOut, currentToken, nextToken);
                            } catch {
                                // Use a conservative default
                                splitMinAmountOut = splitAmount / 2; // 50% slippage as fallback
                            }
                        } else {
                            // Proportional slice of user's minAmountOut
                            splitMinAmountOut = (amountOutMin * split.percentage) / 10000;
                        }
                    }
                }

                // Execute the swap
                uint[] memory amountsOut;

                // Handle ETH input in first hop
                if (hopIndex == 0 && isETHInput) {
                    // Unwrap WETH back to ETH for the swap
                    IWETH(WETH).withdraw(splitAmount);

                    // ETH to token swap
                    amountsOut = IUniswapV2Router02(split.router).swapExactETHForTokens{value: splitAmount}(
                        splitMinAmountOut,
                        split.path,
                        address(this),
                        deadline
                    );
                } 
                else if (nextToken == WETH && hopIndex == route.hops - 1) {
                    require(IERC20(currentToken).approve(split.router, splitAmount), "Approve failed");

                    amountsOut = IUniswapV2Router02(split.router).swapExactTokensForETH(
                        splitAmount,
                        splitMinAmountOut, 
                        split.path,
                        address(this),
                        deadline
                    );
                } 
                else {
                    require(IERC20(currentToken).approve(split.router, splitAmount), "Approve failed");

                    amountsOut = IUniswapV2Router02(split.router).swapExactTokensForTokens(
                        splitAmount,
                        splitMinAmountOut, 
                        split.path,
                        address(this),
                        deadline
                    );
                }

                nextAmountOut += amountsOut[amountsOut.length - 1];
            }

            // Update for next hop
            currentToken = nextToken;
            amountOut = nextAmountOut;
        }

        // Verify minimum output amount if specified by user
        if (amountOutMin > 0) {
            require(amountOut >= amountOutMin, "Insufficient output amount");
        }

        if (route.outputToken == WETH) {
            bool isETHOutput = false;
            if (route.hops > 0 && route.splitRoutes.length > 0) {
                Split[] memory lastHopSplits = route.splitRoutes[route.hops - 1];
                if (lastHopSplits.length > 0) {
                    for (uint i = 0; i < lastHopSplits.length; i++) {
                        Split memory split = lastHopSplits[i];
                        if (split.router != address(0) && split.path.length > 0) {
                            if (split.path[split.path.length - 1] == WETH) {
                                isETHOutput = true;
                                break;
                            }
                        }
                    }
                }
            }

            if (isETHOutput) {
                payable(msg.sender).transfer(amountOut);
            } else {
                IWETH(WETH).withdraw(amountOut);
                payable(msg.sender).transfer(amountOut);
            }
        } else {
            // Transfer tokens to user
            require(IERC20(route.outputToken).transfer(msg.sender, amountOut), "Output transfer failed");
        }

        emit SwapExecuted(msg.sender, amountIn, amountOut, priceImpactBps);
    }
    
    // Helper function to estimate token exchange rate
    function getTokenOutValueInTokenIn(address tokenOut, address tokenIn, uint amount) internal view returns (uint) {
        if (tokenIn == tokenOut) return amount;
        
        // Try to estimate value through WETH as common denominator
        if (tokenIn != WETH && tokenOut != WETH) {
            // First get tokenOut -> WETH rate
            uint wethAmount = 0;
            try IUniswapV2Router02(routers[0]).getAmountsOut(
                amount, 
                getPath(tokenOut, WETH)
            ) returns (uint[] memory amounts) {
                wethAmount = amounts[amounts.length-1];
            } catch {
                return amount; // Fallback if route doesn't exist
            }
            
            // Then get WETH -> tokenIn rate
            if (wethAmount > 0) {
                try IUniswapV2Router02(routers[0]).getAmountsOut(
                    wethAmount, 
                    getPath(WETH, tokenIn)
                ) returns (uint[] memory amounts) {
                    return amounts[amounts.length-1];
                } catch {
                    return amount; // Fallback if route doesn't exist
                }
            }
        }
        
        // Direct conversion
        try IUniswapV2Router02(routers[0]).getAmountsOut(
            amount, 
            getPath(tokenOut, tokenIn)
        ) returns (uint[] memory amounts) {
            return amounts[amounts.length-1];
        } catch {
            return amount; // Fallback if route doesn't exist
        }
    }
    
    // Internal function to calculate price impact
    function calculatePriceImpactInternal(uint amountIn, TradeRoute memory route) internal view returns (uint expectedOut, bool highImpact) {
        // First get the expected output
        expectedOut = 0;
        if (route.hops > 0) {
            expectedOut = getExpectedOutputForRoute(amountIn, route);
        }
        
        if (expectedOut == 0) {
            return (0, true);
        }
        
        // Calculate price impact
        uint priceImpactBps = calculateComplexPriceImpact(amountIn, expectedOut, route);
        
        // High impact if over 5%
        highImpact = priceImpactBps > 500; 
        
        return (expectedOut, highImpact);
    }

    receive() external payable {}
}
