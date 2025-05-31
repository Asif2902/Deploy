
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
    uint public constant MAX_HOPS = 8;
    uint public constant MAX_SPLITS_PER_HOP = 4;

    // Default slippage tolerance in basis points (0.5%)
    uint public defaultSlippageBps = 50;
    // Minimum acceptable slippage tolerance in basis points (0.1%)
    uint public minSlippageBps = 10;
    // Maximum slippage tolerance for high volatility tokens (5%)
    uint public maxSlippageBps = 500;

    uint public constant SPLIT_THRESHOLD_BPS = 50;

    uint public constant FEE_DIVISOR = 1000; 
    uint public feeAccumulatedETH;
    mapping(address => uint) public feeAccumulatedTokens;
    address public WETH;

    mapping(address => bool) public whitelistedTokens;

    // Popular stablecoins (only hardcoded addresses allowed)
    address public constant USDT = 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D;
    address public constant USDC = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea;

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

    struct RouteSearchParams {
        uint amountIn;
        address inputToken;
        address outputToken;
        uint bestOutputLocal;
        address[] potentialIntermediates;
    }

    struct SplitSearchResult {
        uint output;
        Split[] splits;
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

    event RouterAdded(address router);
    event RouterRemoved(address router);
    event TokenWhitelisted(address token);
    event TokenRemovedFromWhitelist(address token);
    event SwapExecuted(address indexed user, uint amountIn, uint amountOut);
    event FeesWithdrawn(address indexed owner, uint ethAmount);
    event TokenFeesWithdrawn(address indexed owner, address token, uint amount);
    event SlippageConfigUpdated(uint defaultSlippageBps, uint minSlippageBps, uint maxSlippageBps);

    constructor(address _weth) {
        owner = msg.sender;
        WETH = _weth;
        whitelistedTokens[_weth] = true;
        // Whitelist the two popular stablecoins
        whitelistedTokens[USDT] = true;
        whitelistedTokens[USDC] = true;
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
            require(_routers[i] != address(0), "Router cannot be zero address");
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
            require(tokens[i] != address(0), "Token cannot be zero address");
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

    function findBestRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (TradeRoute memory route, uint expectedOut) {
        // Input validations
        require(amountIn > 0, "Amount must be greater than 0");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(inputToken != outputToken, "Input and output tokens must be different");
        require(routers.length > 0, "No routers configured");

        // Initialize the trade route
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        expectedOut = 0;
        
        // Try direct route first
        (uint directOutput, Split[] memory directSplits) = findBestSplitForHop(
            amountIn,
            inputToken,
            outputToken,
            new address[](0)
        );
        
        if (directOutput > 0 && directSplits.length > 0) {
            bestRoute.hops = 1;
            bestRoute.splitRoutes = new Split[][](1);
            bestRoute.splitRoutes[0] = directSplits;
            expectedOut = directOutput;
            
            // If we find a good direct route, return it immediately to save gas
            if (expectedOut > amountIn / 2) {
                return (bestRoute, expectedOut);
            }
        }

        // Try two-hop route through WETH if neither token is WETH
        if (inputToken != WETH && outputToken != WETH) {
            (address inToWethRouter, uint wethOutput) = findBestRouterForPair(
                amountIn,
                inputToken,
                WETH
            );
            
            if (wethOutput > 0 && inToWethRouter != address(0)) {
                
                (address wethToOutRouter, uint finalOutput) = findBestRouterForPair(
                    wethOutput,
                    WETH,
                    outputToken
                );
                
                if (finalOutput > 0 && wethToOutRouter != address(0) && finalOutput > expectedOut) {
                        
                        TradeRoute memory wethRoute;
                    wethRoute.inputToken = inputToken;
                    wethRoute.outputToken = outputToken;
                    wethRoute.hops = 2;
                    wethRoute.splitRoutes = new Split[][](2);
                    
                    // First hop
                    wethRoute.splitRoutes[0] = new Split[](1);
                    wethRoute.splitRoutes[0][0] = Split({
                        router: inToWethRouter,
                        percentage: 10000, // 100%
                        path: getPath(inputToken, WETH)
                    });
                    
                    // Second hop
                    wethRoute.splitRoutes[1] = new Split[](1);
                    wethRoute.splitRoutes[1][0] = Split({
                        router: wethToOutRouter,
                        percentage: 10000, // 100%
                        path: getPath(WETH, outputToken)
                    });
                    
                    bestRoute = wethRoute;
                    expectedOut = finalOutput;
                }
            }
        }
        
        // Try stablecoin routes with popular stablecoins
        address[2] memory stablecoins = [USDT, USDC];
        for (uint i = 0; i < stablecoins.length; i++) {
            address stablecoin = stablecoins[i];
            if (stablecoin == inputToken || stablecoin == outputToken) {
                continue;
            }
            
            (address bestRouterFirst, uint firstHopOutput) = findBestRouterForPair(
                amountIn,
                inputToken,
                stablecoin
            );
            
            if (firstHopOutput > 0 && bestRouterFirst != address(0)) {
                (address bestRouterSecond, uint secondHopOutput) = findBestRouterForPair(
                    firstHopOutput,
                    stablecoin,
                    outputToken
                );
                
                if (secondHopOutput > expectedOut && bestRouterSecond != address(0)) {
                    TradeRoute memory newRoute;
                    newRoute.inputToken = inputToken;
                    newRoute.outputToken = outputToken;
                    newRoute.hops = 2;
                    newRoute.splitRoutes = new Split[][](2);
                    
                    // First hop
                    newRoute.splitRoutes[0] = new Split[](1);
                    newRoute.splitRoutes[0][0] = Split({
                        router: bestRouterFirst,
                        percentage: 10000, // 100%
                        path: getPath(inputToken, stablecoin)
                    });
                    
                    // Second hop
                    newRoute.splitRoutes[1] = new Split[](1);
                    newRoute.splitRoutes[1][0] = Split({
                        router: bestRouterSecond,
                        percentage: 10000, // 100%
                        path: getPath(stablecoin, outputToken)
                    });

                    bestRoute = newRoute;
                    expectedOut = secondHopOutput;
                }
            }
        }
        
        // Try progressively more complex routes for maximum output
        // Start with 2-hop routes and go up to 8-hop routes
        for (uint hopCount = 2; hopCount <= MAX_HOPS; hopCount++) {
            // Skip if we already found a very good route (>95% of input value)
            if (expectedOut > 0 && expectedOut > amountIn * 95 / 100) {
                break;
            }
            
            (uint multiHopOutput, TradeRoute memory multiHopRoute) = findBestMultiHopRoute(
                amountIn,
                inputToken,
                outputToken,
                hopCount,
                new address[](0)
            );
            
            if (multiHopOutput > 0) {
                
                if (multiHopOutput > expectedOut && multiHopRoute.hops > 0) {
                    bestRoute = multiHopRoute;
                    expectedOut = multiHopOutput;
                }
            }
            
            // Also try the specialized two-hop route for comparison
            if (hopCount == 2) {
                (uint twoHopOutput, TradeRoute memory twoHopRoute) = findBestTwoHopRoute(
                    amountIn,
                    inputToken,
                    outputToken,
                    new address[](0)
                );
                
                if (twoHopOutput > 0) {
                    
                    if (twoHopOutput > expectedOut && twoHopRoute.hops > 0) {
                        bestRoute = twoHopRoute;
                        expectedOut = twoHopOutput;
                    }
                }
            }
        }
        
        // Enhanced greedy search: Try alternative routing strategies
        (uint greedyOutput, TradeRoute memory greedyRoute) = findBestGreedyRoute(
            amountIn,
            inputToken,
            outputToken
        );
        
        if (greedyOutput > 0) {
            
            if (greedyOutput > expectedOut && greedyRoute.hops > 0) {
                bestRoute = greedyRoute;
                expectedOut = greedyOutput;
            }
        }

        // Ensure we have a valid route
        if (expectedOut > 0 && bestRoute.hops > 0) {
            route = bestRoute;
        } else {
            // Return empty route with 0 expected output if no valid route found
            route = TradeRoute({
                inputToken: inputToken,
                outputToken: outputToken,
                hops: 0,
                splitRoutes: new Split[][](0)
            });
            expectedOut = 0;
        }
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
                if (intermediateToken == address(0) ||
                    !isWhitelisted(intermediateToken) || 
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
            if (firstHopToken == address(0) ||
                !isWhitelisted(firstHopToken) || 
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
            if (currentNextToken == address(0)) continue;
            
            bool alreadyUsed = false;
            for (uint j = 0; j < usedIntermediates.length; j++) {
                if (usedIntermediates[j] == currentNextToken) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed || !isWhitelisted(currentNextToken) || 
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
        // Return tokens that are whitelisted - this will be dynamic based on whitelisted tokens
        // For now, we'll create a basic list with known tokens and iterate through all possible whitelisted tokens
        
        // Create a temporary array to collect whitelisted tokens
        address[] memory tempTokens = new address[](1000); // Max size
        uint count = 0;
        
        // Add WETH and stablecoins first (always whitelisted)
        tempTokens[count++] = WETH;
        tempTokens[count++] = USDT;
        tempTokens[count++] = USDC;
        
        // In a real implementation, you would iterate through all known token addresses
        // or maintain a separate array of whitelisted tokens for efficiency
        
        // Create properly sized result array
        address[] memory result = new address[](count);
        for (uint i = 0; i < count; i++) {
            result[i] = tempTokens[i];
        }
        
        return result;
    }
    
    // Helper function to analyze liquidity depth for a token pair
    function analyzeLiquidityDepth(address tokenA, address tokenB) internal view returns (uint) {
        if (tokenA == address(0) || tokenB == address(0)) {
            return 0;
        }
        
        uint totalLiquidity = 0;
        
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;
            
            try IUniswapV2Router02(routers[i]).factory() returns (address factory) {
                if (factory == address(0)) continue;
                
                try IUniswapV2Factory(factory).getPair(tokenA, tokenB) returns (address pair) {
                    if (pair != address(0)) {
                        try IUniswapV2Pair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
                            address token0;
                            try IUniswapV2Pair(pair).token0() returns (address t0) {
                                token0 = t0;
                            } catch {
                                continue;
                            }
                            
                            uint8 decimalsA = 18;
                            uint8 decimalsB = 18;
                            
                            try IERC20(tokenA).decimals() returns (uint8 dec) {
                                decimalsA = dec;
                            } catch {
                                // Use default 18
                            }
                            
                            try IERC20(tokenB).decimals() returns (uint8 dec) {
                                decimalsB = dec;
                            } catch {
                                // Use default 18
                            }
                            
                            // Normalize reserves to 18 decimals for comparison
                            uint adjustedReserve0;
                            uint adjustedReserve1;
                            
                            if (token0 == tokenA) {
                                adjustedReserve0 = decimalsA == 18 ? uint(reserve0) : 
                                                   uint(reserve0) * (10 ** (18 - decimalsA));
                                adjustedReserve1 = decimalsB == 18 ? uint(reserve1) : 
                                                   uint(reserve1) * (10 ** (18 - decimalsB));
                            } else {
                                adjustedReserve0 = decimalsB == 18 ? uint(reserve0) : 
                                                   uint(reserve0) * (10 ** (18 - decimalsB));
                                adjustedReserve1 = decimalsA == 18 ? uint(reserve1) : 
                                                   uint(reserve1) * (10 ** (18 - decimalsA));
                            }
                            
                            // Use geometric mean of reserves as liquidity metric
                            if (adjustedReserve0 > 0 && adjustedReserve1 > 0) {
                                uint liquidity = sqrt(adjustedReserve0 * adjustedReserve1);
                                totalLiquidity += liquidity;
                            }
                        } catch {
                            // Continue if getReserves fails
                        }
                    }
                } catch {
                    // Continue if getPair fails
                }
            } catch {
                // Continue if factory() fails
            }
        }
        
        return totalLiquidity;
    }
    
    // Helper function for square root calculation (for geometric mean)
    function sqrt(uint x) internal pure returns (uint y) {
        if (x == 0) return 0;
        
        // Binary search approximation
        uint z = (x + 1) / 2;
        y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
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
        // For 4-hop routes, recurse for remaining hops
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
                if (intermediateTokens[j] == address(0)) continue;
                
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
    ) public view returns (uint expectedOut, TradeRoute memory bestRoute) {
        require(hops >= 2 && hops <= MAX_HOPS, "Invalid hop count");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(amountIn > 0, "Amount must be greater than 0");

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
        uint validIntermediateCount = 0;
        
        // Count valid intermediates first
        for (uint i = 0; i < whitelistedIntermediates.length; i++) {
            if (whitelistedIntermediates[i] != address(0) && 
                whitelistedIntermediates[i] != inputToken && 
                whitelistedIntermediates[i] != outputToken) {
                validIntermediateCount++;
            }
        }
        
        // Add input and output tokens for potential routes
        uint intermediateLength = validIntermediateCount + 2;
        address[] memory intermediateTokens = new address[](intermediateLength);
        
        // Fill the array with valid intermediates
        uint idx = 0;
        for (uint i = 0; i < whitelistedIntermediates.length && idx < validIntermediateCount; i++) {
            if (whitelistedIntermediates[i] != address(0) && 
                whitelistedIntermediates[i] != inputToken && 
                whitelistedIntermediates[i] != outputToken) {
                intermediateTokens[idx++] = whitelistedIntermediates[i];
            }
        }
        
        // Add input and output tokens as potential intermediates
        intermediateTokens[intermediateLength - 2] = inputToken;
        intermediateTokens[intermediateLength - 1] = outputToken;
        
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
            
            if (firstHopOutput == 0 || firstHopSplits.length == 0) continue;
            
            // Try recursive approach
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
                for (uint k = 0; k < hops - 1 && k < remainingRoute.splitRoutes.length; k++) {
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
        // Validate token address
        if (token == address(0)) return false;
        
        // Allow if token is the input or output token for the current transaction
        // This allows complex routes like X→Y→X→Z where X is not whitelisted
        if (token == inputToken || token == outputToken) {
            return true;
        }
        
        // Allow WETH as an intermediate token to improve routing possibilities
        if (token == WETH) {
            return true;
        }
        
        // Check if token is in forbidden list (only if we have forbidden tokens)
        if (forbiddenTokens.length > 0) {
            for (uint i = 0; i < forbiddenTokens.length; i++) {
                if (token == forbiddenTokens[i]) return false;
            }
        }
        
        // Otherwise, must be whitelisted
        return isWhitelisted(token);
    }

    // Enhanced greedy algorithm for finding the best route with maximum output
    function findBestGreedyRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) public view returns (uint expectedOut, TradeRoute memory route) {
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(amountIn > 0, "Amount must be greater than 0");
        
        uint bestOutput = 0;
        TradeRoute memory bestRoute;
        
        // Try all hop counts from 1 to MAX_HOPS with different strategies
        for (uint hops = 1; hops <= MAX_HOPS; hops++) {
            // Strategy 1: Liquidity-prioritized routing
            (uint liquidityOutput, TradeRoute memory liquidityRoute) = findLiquidityOptimizedRoute(
                amountIn, inputToken, outputToken, hops
            );
            
            if (liquidityOutput > bestOutput) {
                bestOutput = liquidityOutput;
                bestRoute = liquidityRoute;
            }
            
            // Strategy 2: Volume-prioritized routing
            (uint volumeOutput, TradeRoute memory volumeRoute) = findVolumeOptimizedRoute(
                amountIn, inputToken, outputToken, hops
            );
            
            if (volumeOutput > bestOutput) {
                bestOutput = volumeOutput;
                bestRoute = volumeRoute;
            }
            
            // Strategy 3: Hybrid approach with split optimization
            (uint hybridOutput, TradeRoute memory hybridRoute) = findHybridOptimizedRoute(
                amountIn, inputToken, outputToken, hops
            );
            
            if (hybridOutput > bestOutput) {
                bestOutput = hybridOutput;
                bestRoute = hybridRoute;
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Strategy 1: Optimize for liquidity depth
    function findLiquidityOptimizedRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint targetHops
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (targetHops == 1) {
            // Convert Split[] to TradeRoute
            (uint output, Split[] memory splits) = findBestSplitForHop(amountIn, inputToken, outputToken, new address[](0));
            if (output > 0 && splits.length > 0) {
                route.inputToken = inputToken;
                route.outputToken = outputToken;
                route.hops = 1;
                route.splitRoutes = new Split[][](1);
                route.splitRoutes[0] = splits;
                return (output, route);
            }
            return (0, route);
        }
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = targetHops;
        bestRoute.splitRoutes = new Split[][](targetHops);
        
        uint bestOutput = 0;
        address[] memory intermediates = getAllWhitelistedTokens();
        
        // Rank intermediates by liquidity with input token
        address[] memory liquidityRanked = rankByLiquidity(inputToken, intermediates);
        
        // Try top liquidity tokens as first hop
        for (uint i = 0; i < liquidityRanked.length && i < 5; i++) {
            address firstHop = liquidityRanked[i];
            if (firstHop == address(0) || firstHop == inputToken || firstHop == outputToken) continue;
            
            (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                amountIn, inputToken, firstHop, new address[](0)
            );
            
            if (firstHopOutput == 0) continue;
            
            // Recursively find best path for remaining hops
            (uint remainingOutput, TradeRoute memory remainingRoute) = findLiquidityOptimizedRoute(
                firstHopOutput, firstHop, outputToken, targetHops - 1
            );
            
            if (remainingOutput > bestOutput) {
                bestOutput = remainingOutput;
                bestRoute.splitRoutes[0] = firstHopSplits;
                for (uint j = 1; j < targetHops && j-1 < remainingRoute.splitRoutes.length; j++) {
                    bestRoute.splitRoutes[j] = remainingRoute.splitRoutes[j-1];
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Strategy 2: Optimize for trading volume/activity
    function findVolumeOptimizedRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint targetHops
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (targetHops == 1) {
            // Convert Split[] to TradeRoute
            (uint output, Split[] memory splits) = findBestSplitForHop(amountIn, inputToken, outputToken, new address[](0));
            if (output > 0 && splits.length > 0) {
                route.inputToken = inputToken;
                route.outputToken = outputToken;
                route.hops = 1;
                route.splitRoutes = new Split[][](1);
                route.splitRoutes[0] = splits;
                return (output, route);
            }
            return (0, route);
        }
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = targetHops;
        bestRoute.splitRoutes = new Split[][](targetHops);
        
        uint bestOutput = 0;
        address[] memory highVolumeTokens = getHighVolumeTokens();
        
        // Try high-volume tokens as intermediates
        for (uint i = 0; i < highVolumeTokens.length; i++) {
            address intermediate = highVolumeTokens[i];
            if (intermediate == address(0) || intermediate == inputToken || intermediate == outputToken) continue;
            
            (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                amountIn, inputToken, intermediate, new address[](0)
            );
            
            if (firstHopOutput == 0) continue;
            
            // Recursively find best path for remaining hops
            (uint remainingOutput, TradeRoute memory remainingRoute) = findVolumeOptimizedRoute(
                firstHopOutput, intermediate, outputToken, targetHops - 1
            );
            
            if (remainingOutput > bestOutput) {
                bestOutput = remainingOutput;
                bestRoute.splitRoutes[0] = firstHopSplits;
                for (uint j = 1; j < targetHops && j-1 < remainingRoute.splitRoutes.length; j++) {
                    bestRoute.splitRoutes[j] = remainingRoute.splitRoutes[j-1];
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Strategy 3: Hybrid approach combining liquidity and volume optimization
    function findHybridOptimizedRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint targetHops
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (targetHops == 1) {
            // Convert Split[] to TradeRoute
            (uint output, Split[] memory splits) = findBestSplitForHop(amountIn, inputToken, outputToken, new address[](0));
            if (output > 0 && splits.length > 0) {
                route.inputToken = inputToken;
                route.outputToken = outputToken;
                route.hops = 1;
                route.splitRoutes = new Split[][](1);
                route.splitRoutes[0] = splits;
                return (output, route);
            }
            return (0, route);
        }
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = targetHops;
        bestRoute.splitRoutes = new Split[][](targetHops);
        
        uint bestOutput = 0;
        
        // Combine multiple token lists for comprehensive search
        address[] memory allCandidates = getCombinedCandidateTokens(inputToken, outputToken);
        
        // Try different routing patterns
        for (uint pattern = 0; pattern < 3; pattern++) {
            for (uint i = 0; i < allCandidates.length && i < 8; i++) {
                address firstHop = allCandidates[i];
                if (firstHop == address(0) || firstHop == inputToken || firstHop == outputToken) continue;
                
                // Pattern 0: Standard routing
                // Pattern 1: Prefer stablecoins in middle hops
                // Pattern 2: Prefer high-liquidity tokens
                if (pattern == 1 && !isStablecoin(firstHop)) continue;
                if (pattern == 2 && analyzeLiquidityDepth(inputToken, firstHop) < 1000000) continue;
                
                (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                    amountIn, inputToken, firstHop, new address[](0)
                );
                
                if (firstHopOutput == 0) continue;
                
                // Use different strategies for remaining hops based on pattern
                uint remainingOutput;
                TradeRoute memory remainingRoute;
                
                if (pattern == 0) {
                    (remainingOutput, remainingRoute) = findHybridOptimizedRoute(
                        firstHopOutput, firstHop, outputToken, targetHops - 1
                    );
                } else if (pattern == 1) {
                    (remainingOutput, remainingRoute) = findLiquidityOptimizedRoute(
                        firstHopOutput, firstHop, outputToken, targetHops - 1
                    );
                } else {
                    (remainingOutput, remainingRoute) = findVolumeOptimizedRoute(
                        firstHopOutput, firstHop, outputToken, targetHops - 1
                    );
                }
                
                if (remainingOutput > bestOutput) {
                    bestOutput = remainingOutput;
                    bestRoute.splitRoutes[0] = firstHopSplits;
                    for (uint j = 1; j < targetHops && j-1 < remainingRoute.splitRoutes.length; j++) {
                        bestRoute.splitRoutes[j] = remainingRoute.splitRoutes[j-1];
                    }
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Helper function to rank tokens by liquidity
    function rankByLiquidity(address baseToken, address[] memory tokens) internal view returns (address[] memory) {
        address[] memory ranked = new address[](tokens.length);
        uint[] memory liquidityScores = new uint[](tokens.length);
        
        for (uint i = 0; i < tokens.length; i++) {
            ranked[i] = tokens[i];
            if (tokens[i] != address(0) && tokens[i] != baseToken) {
                liquidityScores[i] = analyzeLiquidityDepth(baseToken, tokens[i]);
            }
        }
        
        // Sort by liquidity (bubble sort)
        for (uint i = 0; i < ranked.length; i++) {
            for (uint j = i + 1; j < ranked.length; j++) {
                if (liquidityScores[j] > liquidityScores[i]) {
                    // Swap
                    address tempToken = ranked[i];
                    ranked[i] = ranked[j];
                    ranked[j] = tempToken;
                    
                    uint tempScore = liquidityScores[i];
                    liquidityScores[i] = liquidityScores[j];
                    liquidityScores[j] = tempScore;
                }
            }
        }
        
        return ranked;
    }
    
    // Get high-volume tokens (using whitelisted tokens dynamically)
    function getHighVolumeTokens() internal view returns (address[] memory) {
        // Return dynamic list based on whitelisted tokens
        return getAllWhitelistedTokens();
    }
    
    // Get combined candidate tokens for comprehensive search
    function getCombinedCandidateTokens(address inputToken, address outputToken) internal view returns (address[] memory) {
        return getAllWhitelistedTokens();
    }
    
    // Check if token is a stablecoin
    function isStablecoin(address token) internal pure returns (bool) {
        return token == USDT || token == USDC;
    }

    function getCommonIntermediates() internal view returns (address[] memory) {
        // Return dynamic list based on whitelisted tokens
        return getAllWhitelistedTokens();
    }

    function getCommonStablecoins() public pure returns (address[] memory) {
        address[] memory stablecoins = new address[](2);
        stablecoins[0] = USDT;
        stablecoins[1] = USDC;
        return stablecoins;
    }

    function getPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) {
            address[] memory emptyPath = new address[](2);
            emptyPath[0] = tokenIn;
            emptyPath[1] = tokenOut;
            return emptyPath;
        }
        
        // Direct path
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;
        
        // Always check direct path first, it's the most efficient
        bool hasDirectLiquidity = false;
        for (uint i = 0; i < routers.length && !hasDirectLiquidity; i++) {
            if (routers[i] == address(0)) continue;
            
            try IUniswapV2Router02(routers[i]).getAmountsOut(1, directPath) returns (uint[] memory amounts) {
                if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                    hasDirectLiquidity = true;
                }
            } catch {
                // Continue checking other routers
            }
        }
        
        if (hasDirectLiquidity) {
            return directPath;
        }
        
        // Try WETH as intermediate (most common)
        if (tokenIn != WETH && tokenOut != WETH) {
            address[] memory wethPath = new address[](3);
            wethPath[0] = tokenIn;
            wethPath[1] = WETH;
            wethPath[2] = tokenOut;
            
            for (uint i = 0; i < routers.length; i++) {
                if (routers[i] == address(0)) continue;
                
                try IUniswapV2Router02(routers[i]).getAmountsOut(1, wethPath) returns (uint[] memory amounts) {
                    if (amounts.length > 2 && amounts[amounts.length - 1] > 0) {
                        return wethPath;
                    }
                } catch {
                    // Continue checking other routers
                }
            }
        }
        
        // Try stablecoins as intermediates
        address[2] memory stablecoins = [USDT, USDC];
        for (uint i = 0; i < stablecoins.length; i++) {
            address stablecoin = stablecoins[i];
            if (stablecoin != tokenIn && stablecoin != tokenOut) {
                address[] memory stablePath = new address[](3);
                stablePath[0] = tokenIn;
                stablePath[1] = stablecoin;
                stablePath[2] = tokenOut;
                
                for (uint j = 0; j < routers.length; j++) {
                    if (routers[j] == address(0)) continue;
                    
                    try IUniswapV2Router02(routers[j]).getAmountsOut(1, stablePath) returns (uint[] memory amounts) {
                        if (amounts.length > 2 && amounts[amounts.length - 1] > 0) {
                            return stablePath;
                        }
                    } catch {
                        // Continue checking other routers
                    }
                }
            }
        }
        
        // Return direct path as fallback
        return directPath;
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

    // Simplified findBestTwoHopRoute to reduce stack depth
    function findBestTwoHopRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        address[] memory /* forbiddenTokens */
    ) public view returns (uint expectedOut, TradeRoute memory route) {
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(amountIn > 0, "Amount must be greater than 0");
        
        RouteSearchParams memory params;
        params.amountIn = amountIn;
        params.inputToken = inputToken;
        params.outputToken = outputToken;
        params.bestOutputLocal = 0;
        
        // Get potential intermediate tokens
        address[] memory whitelistedIntermediates = getAllWhitelistedTokens();
        
        // Count valid intermediates
        uint validCount = 0;
        for (uint i = 0; i < whitelistedIntermediates.length; i++) {
            if (whitelistedIntermediates[i] != address(0)) {
                validCount++;
            }
        }
        
        params.potentialIntermediates = new address[](validCount + 2);
        
        // Add whitelisted tokens
        uint idx = 0;
        for (uint i = 0; i < whitelistedIntermediates.length && idx < validCount; i++) {
            if (whitelistedIntermediates[i] != address(0)) {
                params.potentialIntermediates[idx++] = whitelistedIntermediates[i];
            }
        }
        
        // Also add input and output tokens as potential intermediates
        params.potentialIntermediates[validCount] = inputToken;
        params.potentialIntermediates[validCount + 1] = outputToken;

        // Find common tokens that have high liquidity with both input and output
        params.potentialIntermediates = rankIntermediateTokens(inputToken, outputToken, params.potentialIntermediates);

        return _findBestTwoHopRouteInternal(params);
    }
    
    // Internal function to handle the core two-hop route finding logic
    function _findBestTwoHopRouteInternal(
        RouteSearchParams memory params
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = params.inputToken;
        bestRouteLocal.outputToken = params.outputToken;
        bestRouteLocal.hops = 2;
        bestRouteLocal.splitRoutes = new Split[][](2);

        SplitSearchResult memory bestFirstHop;
        SplitSearchResult memory bestSecondHop;
        
        // Try all possible intermediates with priority to high-liquidity pairs
        for (uint i = 0; i < params.potentialIntermediates.length; i++) {
            address intermediate = params.potentialIntermediates[i];
            
            // Skip empty addresses
            if (intermediate == address(0)) continue;
            
            // Only use token if it's whitelisted or an input/output token
            if (!isWhitelisted(intermediate) && 
                intermediate != params.inputToken && 
                intermediate != params.outputToken) continue;
                
            // Standard case: use findBestSplitForHop for both hops with split percentages
            (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                params.amountIn,
                params.inputToken,
                intermediate,
                new address[](0)
            );

            if (firstHopOutput == 0 || firstHopSplits.length == 0) continue;
            
            (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
                firstHopOutput,
                intermediate,
                params.outputToken,
                new address[](0)
            );

            if (secondHopOutput > params.bestOutputLocal && secondHopSplits.length > 0) {
                params.bestOutputLocal = secondHopOutput;
                bestFirstHop.output = firstHopOutput;
                bestFirstHop.splits = firstHopSplits;
                bestSecondHop.output = secondHopOutput;
                bestSecondHop.splits = secondHopSplits;
            }
            
            // Early exit optimization
            if (i < 3 && params.bestOutputLocal > 0) {
                bool shouldContinue = _shouldContinueSearch(params, i);
                if (!shouldContinue) {
                    break;
                }
            }
            
            // Try advanced routing for better output
            uint advancedOutput = _tryAdvancedRouting(params, intermediate);
            if (advancedOutput > params.bestOutputLocal) {
                params.bestOutputLocal = advancedOutput;
                // Update best splits would happen in the advanced routing function
            }
        }

        // Construct the final route
        if (params.bestOutputLocal > 0 && bestFirstHop.splits.length > 0 && bestSecondHop.splits.length > 0) {
            bestRouteLocal.splitRoutes[0] = bestFirstHop.splits;
            bestRouteLocal.splitRoutes[1] = bestSecondHop.splits;
            route = bestRouteLocal;
            expectedOut = params.bestOutputLocal;
        } else {
            // Return empty route with 0 expected output if no valid route found
            route = TradeRoute({
                inputToken: params.inputToken,
                outputToken: params.outputToken,
                hops: 0,
                splitRoutes: new Split[][](0)
            });
            expectedOut = 0;
        }

        return (expectedOut, route);
    }
    
    // Helper function to check if we should continue searching
    function _shouldContinueSearch(
        RouteSearchParams memory params,
        uint currentIndex
    ) internal view returns (bool) {
        // Check if the next ranked token performs significantly better (>5% increase)
        for (uint j = currentIndex + 1; j < params.potentialIntermediates.length && j <= currentIndex + 2; j++) {
            address nextIntermediate = params.potentialIntermediates[j];
            if (nextIntermediate == address(0)) continue;
            
            // Only use token if it's whitelisted or an input/output token
            if (!isWhitelisted(nextIntermediate) && 
                nextIntermediate != params.inputToken && 
                nextIntermediate != params.outputToken) continue;
            
            (uint nextFirstHopOutput, ) = findBestSplitForHop(
                params.amountIn,
                params.inputToken,
                nextIntermediate,
                new address[](0)
            );
            
            if (nextFirstHopOutput == 0) continue;
            
            (uint nextSecondHopOutput, ) = findBestSplitForHop(
                nextFirstHopOutput,
                nextIntermediate,
                params.outputToken,
                new address[](0)
            );
            
            // If next token might give >5% better results, continue checking
            if (nextSecondHopOutput > params.bestOutputLocal * 105 / 100) {
                return true;
            }
        }
        
        return false;
    }
    
    // Helper function to try advanced routing strategies
    function _tryAdvancedRouting(
        RouteSearchParams memory params,
        address intermediate
    ) internal view returns (uint) {
        uint bestAdvancedOutput = 0;
        
        // Try each router for first hop
        for (uint r1 = 0; r1 < routers.length; r1++) {
            address router1 = routers[r1];
            if (router1 == address(0)) continue;
            
            address[] memory path1 = getPath(params.inputToken, intermediate);
            if (path1.length < 2) continue;
            
            uint firstHopOutputWithSplit = 0;
            try IUniswapV2Router02(router1).getAmountsOut(params.amountIn, path1) returns (uint[] memory res) {
                firstHopOutputWithSplit = res[res.length - 1];
            } catch {
                continue;
            }
            
            if (firstHopOutputWithSplit == 0) continue;
            
            // Find the best routers for second hop
            (address[] memory secondHopRouters, uint[] memory secondHopOutputs) = findTopRoutersForPair(
                firstHopOutputWithSplit,
                intermediate,
                params.outputToken,
                MAX_SPLITS_PER_HOP
            );
            
            if (secondHopRouters[0] == address(0)) continue;
            
            // Calculate optimal split percentages
            (uint splitOutput, ) = optimizeSplitPercentages(
                firstHopOutputWithSplit,
                intermediate,
                params.outputToken,
                secondHopRouters
            );
            
            if (splitOutput > bestAdvancedOutput) {
                bestAdvancedOutput = splitOutput;
            }
        }
        
        return bestAdvancedOutput;
    }
    
    // Helper method to rank intermediate tokens by liquidity
    function rankIntermediateTokens(
        address inputToken,
        address outputToken,
        address[] memory intermediates
    ) internal view returns (address[] memory) {
        if (inputToken == address(0) || outputToken == address(0)) {
            return intermediates;
        }
        
        // Create a copy to avoid modifying the original
        address[] memory rankedTokens = new address[](intermediates.length);
        for (uint i = 0; i < intermediates.length; i++) {
            rankedTokens[i] = intermediates[i];
        }
        
        // Calculate liquidity scores
        uint[] memory liquidityScores = new uint[](intermediates.length);
        
        for (uint i = 0; i < intermediates.length; i++) {
            if (rankedTokens[i] == address(0)) continue;
            
            // Analyze liquidity on both sides
            uint liquidityWithInput = analyzeLiquidityDepth(inputToken, rankedTokens[i]);
            uint liquidityWithOutput = analyzeLiquidityDepth(rankedTokens[i], outputToken);
            
            // Score is the geometric mean of liquidity on both sides
            if (liquidityWithInput > 0 && liquidityWithOutput > 0) {
                liquidityScores[i] = sqrt(liquidityWithInput * liquidityWithOutput);
            }
        }
        
        // Sort tokens by liquidity score (bubble sort for simplicity)
        for (uint i = 0; i < rankedTokens.length; i++) {
            for (uint j = i + 1; j < rankedTokens.length; j++) {
                if (liquidityScores[j] > liquidityScores[i]) {
                    // Swap tokens
                    address tempToken = rankedTokens[i];
                    rankedTokens[i] = rankedTokens[j];
                    rankedTokens[j] = tempToken;
                    
                    // Swap scores
                    uint tempScore = liquidityScores[i];
                    liquidityScores[i] = liquidityScores[j];
                    liquidityScores[j] = tempScore;
                }
            }
        }
        
        return rankedTokens;
    }

    function findBestSplitForHop(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory /* forbiddenTokens */
    ) public view returns (uint expectedOut, Split[] memory splits) {
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (0, new Split[](0));
        }
        
        (address bestRouter, uint bestAmountOut) = findBestRouterForPair(amountIn, tokenIn, tokenOut);

        if (bestRouter == address(0) || bestAmountOut == 0) {
            return (0, new Split[](0));
        }

        Split[] memory bestSplits = new Split[](1);
        bestSplits[0] = Split({
            router: bestRouter,
            percentage: 10000, // 100%
            path: getPath(tokenIn, tokenOut)
        });

        uint totalOutput = bestAmountOut;

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
    ) public view returns (address bestRouter, uint bestAmountOut) {
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (address(0), 0);
        }
        
        bestAmountOut = 0;
        bestRouter = address(0);

        // Get direct path once to avoid repeated calls
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;

        // Try direct path first with all routers
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;
            
            try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, directPath) returns (uint[] memory res) {
                if (res.length > 1) {
                    uint amountOut = res[res.length - 1];
                    if (amountOut > bestAmountOut) {
                        bestAmountOut = amountOut;
                        bestRouter = routers[i];
                    }
                }
            } catch {
                // Continue to next router
            }
        }
        
        // If direct path worked, return immediately
        if (bestAmountOut > 0) {
            return (bestRouter, bestAmountOut);
        }
        
        // If WETH is neither input nor output, try through WETH
        if (tokenIn != WETH && tokenOut != WETH) {
            address[] memory wethPath = new address[](3);
            wethPath[0] = tokenIn;
            wethPath[1] = WETH;
            wethPath[2] = tokenOut;
            
            for (uint i = 0; i < routers.length; i++) {
                if (routers[i] == address(0)) continue;
                
                try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, wethPath) returns (uint[] memory res) {
                    if (res.length > 2) {
                        uint amountOut = res[res.length - 1];
                        if (amountOut > bestAmountOut) {
                            bestAmountOut = amountOut;
                            bestRouter = routers[i];
                        }
                    }
                } catch {
                    // Continue to next router
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
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            topRouters = new address[](count);
            amountsOut = new uint[](count);
            return (topRouters, amountsOut);
        }
        
        require(count <= MAX_SPLITS_PER_HOP, "Count exceeds max splits");
        require(count <= routers.length, "Count exceeds router count");

        topRouters = new address[](count);
        amountsOut = new uint[](count);

        // Calculate amounts for all routers
        address[] memory allRouters = new address[](routers.length);
        uint[] memory allAmounts = new uint[](routers.length);
        uint validRouterCount = 0;

        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;
            
            allRouters[validRouterCount] = routers[i];
            address[] memory path = getPath(tokenIn, tokenOut);
            if (path.length < 2) {
                allAmounts[validRouterCount] = 0;
            } else {
                try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                    if (res.length > 1) {
                        allAmounts[validRouterCount] = res[res.length - 1];
                    } else {
                        allAmounts[validRouterCount] = 0;
                    }
                } catch {
                    allAmounts[validRouterCount] = 0;
                }
            }
            validRouterCount++;
        }

        // Sort routers by amount out (simple bubble sort)
        for (uint i = 0; i < validRouterCount; i++) {
            for (uint j = i + 1; j < validRouterCount; j++) {
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
        for (uint i = 0; i < count && i < validRouterCount; i++) {
            if (allAmounts[i] > 0) {
                topRouters[i] = allRouters[i];
                amountsOut[i] = allAmounts[i];
            }
        }
        
        return (topRouters, amountsOut);
    }

    function calculateSplitOutput(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters,
        uint[] memory splitPercentages
    ) internal view returns (uint totalOutput) {
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return 0;
        }
        
        require(splitRouters.length == splitPercentages.length, "Array length mismatch");

        totalOutput = 0;
        address[] memory path = getPath(tokenIn, tokenOut);
        if (path.length < 2) return 0;

        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] == address(0) || splitPercentages[i] == 0) continue;

            uint routerAmountIn = (amountIn * splitPercentages[i]) / 10000;
            if (routerAmountIn == 0) continue;

            try IUniswapV2Router02(splitRouters[i]).getAmountsOut(routerAmountIn, path) returns (uint[] memory amounts) {
                if (amounts.length > 1) {
                    totalOutput += amounts[amounts.length - 1];
                }
            } catch {
                // Skip if router reverts
            }
        }
        
        return totalOutput;
    }

    function optimizeSplitPercentages(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters
    ) internal view returns (uint bestOutput, uint[] memory bestPercentages) {
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (0, new uint[](0));
        }
        
        uint routerCount = 0;
        uint[] memory routerOutputs = new uint[](splitRouters.length);
        uint[] memory smallAmountOutputs = new uint[](splitRouters.length);
        uint[] memory mediumAmountOutputs = new uint[](splitRouters.length);
        uint[] memory largeAmountOutputs = new uint[](splitRouters.length);
        
        uint totalPossibleOutput = 0;
        
        // Test different input amounts to detect price impact
        uint smallAmount = amountIn / 10;            // 10% of input amount
        uint mediumAmount = amountIn / 2;            // 50% of input amount
        uint largeAmount = amountIn;                 // 100% of input amount
        
        // Find valid routers and get outputs for different input sizes
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0)) {
                routerCount++;
                address[] memory path = getPath(tokenIn, tokenOut);
                if (path.length < 2) continue;
                
                // Test with small amount
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(smallAmount, path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        smallAmountOutputs[i] = amounts[amounts.length - 1];
                    }
                } catch {
                    smallAmountOutputs[i] = 0;
                }
                
                // Test with medium amount
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(mediumAmount, path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        mediumAmountOutputs[i] = amounts[amounts.length - 1];
                    }
                } catch {
                    mediumAmountOutputs[i] = 0;
                }
                
                // Test with large amount (full amount)
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(largeAmount, path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        largeAmountOutputs[i] = amounts[amounts.length - 1];
                        routerOutputs[i] = largeAmountOutputs[i];
                        totalPossibleOutput += routerOutputs[i];
                    }
                } catch {
                    largeAmountOutputs[i] = 0;
                    routerOutputs[i] = 0;
                }
            }
        }

        if (routerCount == 0) return (0, new uint[](0));

        // Initialize bestPercentages array
        bestPercentages = new uint[](splitRouters.length);
        
        // Calculate price impact for each router
        int[] memory priceImpacts = calculatePriceImpacts(
            smallAmountOutputs, 
            mediumAmountOutputs, 
            largeAmountOutputs,
            smallAmount,
            mediumAmount,
            largeAmount
        );

        // Analyze if splitting will help
        bool shouldSplit = analyzeSplitPotential(priceImpacts, routerOutputs);
        
        // Set initial percentages based on router outputs but adjusted for price impact
        if (totalPossibleOutput > 0) {
            if (shouldSplit) {
                // More advanced distribution that accounts for price impact
                // Invert price impacts (higher impact = lower percentage)
                int[] memory invertedImpacts = new int[](splitRouters.length);
                uint totalInvertedImpact = 0;
                
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (routerOutputs[i] > 0) {
                        // Max impact to consider is 2000 basis points (20%)
                        int impactValue = priceImpacts[i];
                        int impact = impactValue > 2000 ? int(2000) : impactValue;
                        invertedImpacts[i] = 2000 - impact;
                        if (invertedImpacts[i] < 0) invertedImpacts[i] = 0;
                        totalInvertedImpact += uint(invertedImpacts[i]);
                    }
                }
                
                if (totalInvertedImpact > 0) {
                    // Distribute based on inverted impact (less impact gets more allocation)
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (routerOutputs[i] > 0) {
                            bestPercentages[i] = uint(invertedImpacts[i]) * 10000 / totalInvertedImpact;
                        }
                    }
                } else {
                    // Fallback to output-based distribution
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (routerOutputs[i] > 0) {
                            bestPercentages[i] = (routerOutputs[i] * 10000) / totalPossibleOutput;
                        }
                    }
                }
            } else {
                // If splitting doesn't help, use the best single router
                uint bestSingleIndex = 0;
                uint bestSingleOutput = 0;
                
                for (uint i = 0; i < routerOutputs.length; i++) {
                    if (routerOutputs[i] > bestSingleOutput) {
                        bestSingleOutput = routerOutputs[i];
                        bestSingleIndex = i;
                    }
                }
                
                // Allocate 100% to best router
                bestPercentages[bestSingleIndex] = 10000;
            }

            // Ensure percentages add up to 10000 (100%)
            uint totalPercentage = 0;
            for (uint i = 0; i < bestPercentages.length; i++) {
                totalPercentage += bestPercentages[i];
            }

            if (totalPercentage < 10000) {
                // Find router with highest output for remainder
                uint maxOutput = 0;
                uint maxIndex = 0;
                for (uint i = 0; i < routerOutputs.length; i++) {
                    if (routerOutputs[i] > maxOutput) {
                        maxOutput = routerOutputs[i];
                        maxIndex = i;
                    }
                }
                bestPercentages[maxIndex] += (10000 - totalPercentage);
            } else if (totalPercentage > 10000) {
                // Scale down proportionally if over 100%
                for (uint i = 0; i < bestPercentages.length; i++) {
                    bestPercentages[i] = (bestPercentages[i] * 10000) / totalPercentage;
                }
            }
        } else {
            // Fallback to equal distribution if we couldn't get valid outputs
            uint validRouterCount = 0;
            for (uint i = 0; i < splitRouters.length; i++) {
                if (splitRouters[i] != address(0)) {
                    validRouterCount++;
                }
            }
            
            if (validRouterCount > 0) {
                uint equalShare = 10000 / validRouterCount;
                uint assigned = 0;
                
                for (uint i = 0; i < splitRouters.length && splitRouters[i] != address(0); i++) {
                    bestPercentages[i] = equalShare;
                    assigned += equalShare;
                }
                
                // Assign remainder to first valid router
                if (assigned < 10000) {
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (splitRouters[i] != address(0)) {
                            bestPercentages[i] += (10000 - assigned);
                            break;
                        }
                    }
                }
            }
        }
        
        // Calculate output using these percentages
        bestOutput = calculateSplitOutput(
            amountIn,
            tokenIn,
            tokenOut,
            splitRouters,
            bestPercentages
        );

        // Try additional distributions
        uint[][] memory testDistributions = generateTestDistributions(splitRouters, routerOutputs);
        
        for (uint i = 0; i < testDistributions.length; i++) {
            uint output = calculateSplitOutput(
                amountIn,
                tokenIn,
                tokenOut,
                splitRouters,
                testDistributions[i]
            );

            if (output > bestOutput) {
                bestOutput = output;
                bestPercentages = testDistributions[i];
            }
        }
        
        return (bestOutput, bestPercentages);
    }
    
    // Helper to analyze if splitting trades will help based on price impacts
    function analyzeSplitPotential(int[] memory priceImpacts, uint[] memory routerOutputs) internal pure returns (bool) {
        // Find best single router index
        uint bestRouterIndex = 0;
        uint bestOutput = 0;
        
        for (uint i = 0; i < routerOutputs.length; i++) {
            if (routerOutputs[i] > bestOutput) {
                bestOutput = routerOutputs[i];
                bestRouterIndex = i;
            }
        }
        
        // If no valid router found, can't split
        if (bestOutput == 0) return false;
        
        // Check if any routers have both positive output and lower price impact than best router
        for (uint i = 0; i < routerOutputs.length; i++) {
            if (i != bestRouterIndex && routerOutputs[i] > 0) {
                // If any other router has lower price impact, splitting could help
                if (priceImpacts[i] < priceImpacts[bestRouterIndex]) {
                    return true;
                }
                
                // If output is within 90% of best and there's significant price impact on the best, splitting could help
                if (routerOutputs[i] >= (bestOutput * 9 / 10) && priceImpacts[bestRouterIndex] > 100) {
                    return true;
                }
            }
        }
        
        // If the best router has high price impact, splitting could help regardless
        if (priceImpacts[bestRouterIndex] > 300) { // >3% impact
            return true;
        }
        
        return false;
    }
    
    // Helper to calculate price impacts from test amounts
    function calculatePriceImpacts(
        uint[] memory smallOutputs,
        uint[] memory mediumOutputs,
        uint[] memory largeOutputs,
        uint smallAmount,
        uint mediumAmount,
        uint largeAmount
    ) internal pure returns (int[] memory impacts) {
        impacts = new int[](smallOutputs.length);
        
        for (uint i = 0; i < smallOutputs.length; i++) {
            if (smallOutputs[i] == 0 || largeOutputs[i] == 0) {
                impacts[i] = 10000; // 100% impact (effectively infinite) for invalid routes
                continue;
            }
            
            // Calculate expected output for large amount based on small amount rate
            uint expectedLargeOutput = (smallOutputs[i] * largeAmount) / smallAmount;
            
            // Calculate price impact in basis points (100 = 1%)
            if (expectedLargeOutput > largeOutputs[i]) {
                uint impactRaw = ((expectedLargeOutput - largeOutputs[i]) * 10000) / expectedLargeOutput;
                impacts[i] = int(impactRaw);
            } else {
                impacts[i] = 0; // No price impact (or positive price impact, which shouldn't happen)
            }
        }
        
        return impacts;
    }
    
    // Generate test distributions to find optimal split
    function generateTestDistributions(
        address[] memory splitRouters, 
        uint[] memory routerOutputs
    ) internal pure returns (uint[][] memory) {
        uint routerCount = 0;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0) && routerOutputs[i] > 0) {
                routerCount++;
            }
        }
        
        // Create array of test distributions
        uint[][] memory testDistributions = new uint[][](35);
        
        // Find top routers
        uint[] memory topIndices = new uint[](4); // Store up to top 4 routers
        uint[] memory topOutputs = new uint[](4);
        
        for (uint i = 0; i < routerOutputs.length; i++) {
            if (routerOutputs[i] > topOutputs[0]) {
                // Shift everything down
                topOutputs[3] = topOutputs[2];
                topIndices[3] = topIndices[2];
                topOutputs[2] = topOutputs[1];
                topIndices[2] = topIndices[1];
                topOutputs[1] = topOutputs[0];
                topIndices[1] = topIndices[0];
                topOutputs[0] = routerOutputs[i];
                topIndices[0] = i;
            } else if (routerOutputs[i] > topOutputs[1]) {
                // Shift from 1 down
                topOutputs[3] = topOutputs[2];
                topIndices[3] = topIndices[2];
                topOutputs[2] = topOutputs[1];
                topIndices[2] = topIndices[1];
                topOutputs[1] = routerOutputs[i];
                topIndices[1] = i;
            } else if (routerOutputs[i] > topOutputs[2]) {
                // Shift from 2 down
                topOutputs[3] = topOutputs[2];
                topIndices[3] = topIndices[2];
                topOutputs[2] = routerOutputs[i];
                topIndices[2] = i;
            } else if (routerOutputs[i] > topOutputs[3]) {
                topOutputs[3] = routerOutputs[i];
                topIndices[3] = i;
            }
        }
        
        // 100% to best router
        testDistributions[0] = new uint[](splitRouters.length);
        testDistributions[0][topIndices[0]] = 10000;
        
        if (routerCount >= 2) {
            // 100% to second-best router (for comparison)
            testDistributions[1] = new uint[](splitRouters.length);
            testDistributions[1][topIndices[1]] = 10000;
            
            // Equal distribution among all valid routers
            testDistributions[2] = new uint[](splitRouters.length);
            uint equalShare = 10000 / routerCount;
            uint count = 0;
            
            for (uint i = 0; i < splitRouters.length; i++) {
                if (splitRouters[i] != address(0) && routerOutputs[i] > 0) {
                    testDistributions[2][i] = equalShare;
                    count++;
                    if (count == routerCount - 1) {
                        // Last router gets remainder to ensure 100%
                        testDistributions[2][i] = 10000 - (equalShare * (routerCount - 1));
                        break;
                    }
                }
            }
            
            // Two-way splits between top routers
            for (uint percentageTop = 95; percentageTop >= 55; percentageTop -= 5) {
                uint idx = (95 - percentageTop) / 5 + 3;  // Map to indices 3-11
                testDistributions[idx] = new uint[](splitRouters.length);
                testDistributions[idx][topIndices[0]] = percentageTop * 100;
                testDistributions[idx][topIndices[1]] = (100 - percentageTop) * 100;
            }
            
            // 50-50 split
            testDistributions[12] = new uint[](splitRouters.length);
            testDistributions[12][topIndices[0]] = 5000;
            testDistributions[12][topIndices[1]] = 5000;
            
            // Two-way splits with second router getting more
            for (uint percentageSecond = 55; percentageSecond <= 75; percentageSecond += 5) {
                uint idx = (percentageSecond - 55) / 5 + 13;  // Map to indices 13-17
                testDistributions[idx] = new uint[](splitRouters.length);
                testDistributions[idx][topIndices[0]] = (100 - percentageSecond) * 100;
                testDistributions[idx][topIndices[1]] = percentageSecond * 100;
            }
        }
        
        if (routerCount >= 3) {
            // Three-way splits
            testDistributions[18] = new uint[](splitRouters.length);
            testDistributions[18][topIndices[0]] = 3334;
            testDistributions[18][topIndices[1]] = 3333;
            testDistributions[18][topIndices[2]] = 3333;
            
            testDistributions[19] = new uint[](splitRouters.length);
            testDistributions[19][topIndices[0]] = 5000;
            testDistributions[19][topIndices[1]] = 3000;
            testDistributions[19][topIndices[2]] = 2000;
            
            testDistributions[20] = new uint[](splitRouters.length);
            testDistributions[20][topIndices[0]] = 4000;
            testDistributions[20][topIndices[1]] = 4000;
            testDistributions[20][topIndices[2]] = 2000;
            
            testDistributions[21] = new uint[](splitRouters.length);
            testDistributions[21][topIndices[0]] = 6000;
            testDistributions[21][topIndices[1]] = 2500;
            testDistributions[21][topIndices[2]] = 1500;
            
            testDistributions[22] = new uint[](splitRouters.length);
            testDistributions[22][topIndices[0]] = 7000;
            testDistributions[22][topIndices[1]] = 2000;
            testDistributions[22][topIndices[2]] = 1000;
        }
        
        if (routerCount >= 4) {
            // Four-way splits
            testDistributions[23] = new uint[](splitRouters.length);
            testDistributions[23][topIndices[0]] = 2500;
            testDistributions[23][topIndices[1]] = 2500;
            testDistributions[23][topIndices[2]] = 2500;
            testDistributions[23][topIndices[3]] = 2500;
            
            testDistributions[24] = new uint[](splitRouters.length);
            testDistributions[24][topIndices[0]] = 4000;
            testDistributions[24][topIndices[1]] = 3000;
            testDistributions[24][topIndices[2]] = 2000;
            testDistributions[24][topIndices[3]] = 1000;
            
            // More aggressive weight to best router
            testDistributions[25] = new uint[](splitRouters.length);
            testDistributions[25][topIndices[0]] = 5500;
            testDistributions[25][topIndices[1]] = 2500;
            testDistributions[25][topIndices[2]] = 1500;
            testDistributions[25][topIndices[3]] = 500;
        }
        
        // Dynamic weighted distributions based on output ratios
        if (topOutputs[0] > 0) {
            testDistributions[26] = new uint[](splitRouters.length);
            uint totalWeight = 0;
            
            for (uint i = 0; i < splitRouters.length; i++) {
                if (routerOutputs[i] > 0) {
                    // Weight by square root of output (less aggressive than direct proportion)
                    testDistributions[26][i] = sqrt(routerOutputs[i] * 1e6);
                    totalWeight += testDistributions[26][i];
                }
            }
            
            if (totalWeight > 0) {
                // Normalize to 10000
                uint normalizedTotal = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (testDistributions[26][i] > 0) {
                        testDistributions[26][i] = (testDistributions[26][i] * 10000) / totalWeight;
                        normalizedTotal += testDistributions[26][i];
                    }
                }
                
                // Adjust for rounding
                if (normalizedTotal < 10000 && topIndices[0] < splitRouters.length) {
                    testDistributions[26][topIndices[0]] += (10000 - normalizedTotal);
                }
            }
        }
        
        // Try exponentially weighted distribution
        testDistributions[27] = new uint[](splitRouters.length);
        if (routerCount >= 2) {
            if (routerCount == 2) {
                testDistributions[27][topIndices[0]] = 8000;
                testDistributions[27][topIndices[1]] = 2000;
            } else if (routerCount == 3) {
                testDistributions[27][topIndices[0]] = 7000;
                testDistributions[27][topIndices[1]] = 2100;
                testDistributions[27][topIndices[2]] = 900;
            } else {
                testDistributions[27][topIndices[0]] = 6400;
                testDistributions[27][topIndices[1]] = 2400;
                testDistributions[27][topIndices[2]] = 900;
                testDistributions[27][topIndices[3]] = 300;
            }
        } else {
            testDistributions[27][topIndices[0]] = 10000;
        }
        
        // Additional distributions for diversity
        if (routerCount >= 2) {
            testDistributions[28] = new uint[](splitRouters.length);
            testDistributions[28][topIndices[0]] = 7500;
            testDistributions[28][topIndices[1]] = 2500;
            
            testDistributions[29] = new uint[](splitRouters.length);
            testDistributions[29][topIndices[0]] = 8200;
            testDistributions[29][topIndices[1]] = 1800;
            
            testDistributions[30] = new uint[](splitRouters.length);
            testDistributions[30][topIndices[0]] = 9200;
            testDistributions[30][topIndices[1]] = 800;
            
            if (routerCount >= 3) {
                testDistributions[31] = new uint[](splitRouters.length);
                testDistributions[31][topIndices[0]] = 6200;
                testDistributions[31][topIndices[1]] = 2400;
                testDistributions[31][topIndices[2]] = 1400;
                
                testDistributions[32] = new uint[](splitRouters.length);
                testDistributions[32][topIndices[0]] = 4500;
                testDistributions[32][topIndices[1]] = 3000;
                testDistributions[32][topIndices[2]] = 2500;
                
                if (routerCount >= 4) {
                    testDistributions[33] = new uint[](splitRouters.length);
                    testDistributions[33][topIndices[0]] = 4500;
                    testDistributions[33][topIndices[1]] = 2500;
                    testDistributions[33][topIndices[2]] = 2000;
                    testDistributions[33][topIndices[3]] = 1000;
                    
                    testDistributions[34] = new uint[](splitRouters.length);
                    testDistributions[34][topIndices[0]] = 3500;
                    testDistributions[34][topIndices[1]] = 3000;
                    testDistributions[34][topIndices[2]] = 2500;
                    testDistributions[34][topIndices[3]] = 1000;
                }
            }
        }
        
        return testDistributions;
    }

    // Calculate dynamic slippage based on token volatility
    function calculateDynamicSlippage(address inputToken, address outputToken, uint expectedOut) internal view returns (uint slippageBps) {
        // Start with the default slippage
        slippageBps = defaultSlippageBps;

        // Get decimals to understand token precision 
        uint8 decimalsIn = 18;
        uint8 decimalsOut = 18;

        try IERC20(inputToken).decimals() returns (uint8 dec) {
            decimalsIn = dec;
        } catch {
            // Default to 18 if no decimals function
        }

        try IERC20(outputToken).decimals() returns (uint8 dec) {
            decimalsOut = dec;
        } catch {
            // Default to 18 if no decimals function
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
        require(amountIn > 0, "Amount must be greater than 0");
        require(route.inputToken != address(0) && route.outputToken != address(0), "Invalid tokens");
        require(deadline >= block.timestamp, "Deadline expired");

        // Validate all intermediate tokens are whitelisted
        for (uint i = 0; i < route.hops; i++) {
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                Split memory split = route.splitRoutes[i][j];
                require(split.router != address(0), "Invalid router");
                require(split.path.length >= 2, "Invalid path length");

                // Check all tokens in the path
                for (uint k = 0; k < split.path.length; k++) {
                    address token = split.path[k];
                    require(token != address(0), "Invalid token in path");

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
                if (currentNextToken != route.outputToken && currentNextToken != route.inputToken) {
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
                    try IUniswapV2Router02(split.router).swapExactETHForTokens{value: splitAmount}(
                        splitMinAmountOut,
                        split.path,
                        address(this),
                        deadline
                    ) returns (uint[] memory amounts) {
                        amountsOut = amounts;
                    } catch {
                        // If swap fails, skip this split
                        continue;
                    }
                } 
                else if (nextToken == WETH && hopIndex == route.hops - 1) {
                    try IERC20(currentToken).approve(split.router, splitAmount) returns (bool) {} catch {
                        continue;
                    }

                    try IUniswapV2Router02(split.router).swapExactTokensForETH(
                        splitAmount,
                        splitMinAmountOut, 
                        split.path,
                        address(this),
                        deadline
                    ) returns (uint[] memory amounts) {
                        amountsOut = amounts;
                    } catch {
                        // If swap fails, skip this split
                        continue;
                    }
                } 
                else {
                    try IERC20(currentToken).approve(split.router, splitAmount) returns (bool) {} catch {
                        continue;
                    }

                    try IUniswapV2Router02(split.router).swapExactTokensForTokens(
                        splitAmount,
                        splitMinAmountOut, 
                        split.path,
                        address(this),
                        deadline
                    ) returns (uint[] memory amounts) {
                        amountsOut = amounts;
                    } catch {
                        // If swap fails, skip this split
                        continue;
                    }
                }

                if (amountsOut.length > 0) {
                    nextAmountOut += amountsOut[amountsOut.length - 1];
                }
            }

            // Update for next hop
            currentToken = nextToken;
            amountOut = nextAmountOut;
            
            // If we got 0 output from a hop, fail the transaction
            require(amountOut > 0, "Zero output from hop");
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

        emit SwapExecuted(msg.sender, amountIn, amountOut);
    }

    receive() external payable {}
}
