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
    uint public constant MAX_HOPS = 4;
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

    function findBestRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (TradeRoute memory route, uint expectedOut) {
        // Initialize the trade route
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;

        // Only check direct route if input/output tokens are valid
        if (canUseTokenInRoute(inputToken, inputToken, outputToken, false) && canUseTokenInRoute(outputToken, inputToken, outputToken, false)) {
            (uint directOutput, Split[] memory directSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                outputToken,
                new address[](0)
            );

            bestRoute.hops = 1;
            bestRoute.splitRoutes = new Split[][](1);
            bestRoute.splitRoutes[0] = directSplits;
            expectedOut = directOutput;

            uint uniquePathOutput = findBestRouterSpecificPaths(
                amountIn,
                inputToken,
                outputToken
            );

            if (uniquePathOutput > expectedOut && ((uniquePathOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                expectedOut = uniquePathOutput;
            }
        }


        for (uint hops = 2; hops <= MAX_HOPS; hops++) {
            (uint hopOutput, TradeRoute memory hopRoute) = findBestMultiHopRoute(
                amountIn,
                inputToken,
                outputToken,
                hops,
                new address[](0) 
            );

            if (hopOutput > expectedOut && ((hopOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                bestRoute = hopRoute;
                expectedOut = hopOutput;
            }
        }

        address[] memory commonStablecoins = getCommonStablecoins();
        for (uint i = 0; i < commonStablecoins.length; i++) {
            address stablecoin = commonStablecoins[i];
            if (stablecoin != inputToken && stablecoin != outputToken && isWhitelisted(stablecoin)) {
                (address bestRouterFirst, uint firstHopOutput) = findBestRouterForPair(
                    amountIn,
                    inputToken,
                    stablecoin
                );

                if (firstHopOutput > 0) {
                    (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
                        firstHopOutput,
                        stablecoin,
                        outputToken,
                        new address[](0)
                    );

                    if (secondHopOutput > expectedOut && 
                        ((secondHopOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                        TradeRoute memory newRoute;
                        newRoute.inputToken = inputToken;
                        newRoute.outputToken = outputToken;
                        newRoute.hops = 2;
                        newRoute.splitRoutes = new Split[][](2);
                        newRoute.splitRoutes[0] = new Split[](1);
                        newRoute.splitRoutes[0][0] = Split({
                            router: bestRouterFirst,
                            percentage: 10000, // 100%
                            path: getPath(inputToken, stablecoin)
                        });

                        newRoute.splitRoutes[1] = secondHopSplits;

                        bestRoute = newRoute;
                        expectedOut = secondHopOutput;
                    }
                }
            }
        }

        if (canUseTokenInRoute(inputToken, inputToken, outputToken, false) && canUseTokenInRoute(outputToken, inputToken, outputToken, false)) {
            address[] memory potentialIntermediates = getAllWhitelistedTokens();

            for (uint i = 0; i < potentialIntermediates.length && i < 20; i++) {
                address intermediateToken = potentialIntermediates[i];

                if (intermediateToken != inputToken && intermediateToken != outputToken && isWhitelisted(intermediateToken)) {
                    address[] memory pathFirstHop = getPath(inputToken, intermediateToken);

                    (address bestRouterFirstHop, uint firstHopOutput) = findBestRouterForPair(
                        amountIn,
                        inputToken,
                        intermediateToken
                    );

                    if (firstHopOutput > 0) {
                        (address bestRouterSecondHop, uint secondHopOutput) = findBestRouterForPair(
                            firstHopOutput,
                            intermediateToken,
                            outputToken
                        );

                        if (secondHopOutput > expectedOut && ((secondHopOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                            TradeRoute memory newRoute;
                            newRoute.inputToken = inputToken;
                            newRoute.outputToken = outputToken;
                            newRoute.hops = 2;
                            newRoute.splitRoutes = new Split[][](2);

                            // Set up first hop
                            newRoute.splitRoutes[0] = new Split[](1);
                            newRoute.splitRoutes[0][0] = Split({
                                router: bestRouterFirstHop,
                                percentage: 10000, // 100%
                                path: pathFirstHop
                            });

                            // Set up second hop
                            newRoute.splitRoutes[1] = new Split[](1);
                            newRoute.splitRoutes[1][0] = Split({
                                router: bestRouterSecondHop,
                                percentage: 10000, // 100%
                                path: getPath(intermediateToken, outputToken)
                            });

                            bestRoute = newRoute;
                            expectedOut = secondHopOutput;
                        }
                    }
                }
            }
        }

        route = bestRoute;
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
                if (!isWhitelisted(intermediateToken) || 
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
            if (!isWhitelisted(firstHopToken) || 
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
        return getCommonIntermediates();
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

    // Advanced pathfinding function to explore parallel paths
    function findParallelPaths(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint maxPaths
    ) internal view returns (TradeRoute[] memory routes, uint[] memory outputs) {
        routes = new TradeRoute[](maxPaths);
        outputs = new uint[](maxPaths);

        // First find the best main route using findBestRouteInternal instead of findBestRoute
        TradeRoute memory bestRoute;
        uint bestOutput;
        (bestRoute, bestOutput) = findBestRouteInternal(amountIn, inputToken, outputToken);

        if (bestOutput == 0) return (routes, outputs);

        // Store the best route
        routes[0] = bestRoute;
        outputs[0] = bestOutput;

        // Now try to find alternative routes by excluding intermediate tokens
        uint routeCount = 1;

        // Get a list of all intermediate tokens used in the best route
        address[] memory usedIntermediates = getIntermediateTokens(bestRoute);

        // For each intermediate token, try finding a route excluding it
        for (uint i = 0; i < usedIntermediates.length && routeCount < maxPaths; i++) {
            address excludedToken = usedIntermediates[i];

            // Skip input and output tokens
            if (excludedToken == inputToken || excludedToken == outputToken) continue;

            // Create a list of forbidden tokens for this search
            address[] memory forbidden = new address[](1);
            forbidden[0] = excludedToken;

            // Find best route excluding this token
            TradeRoute memory alternativeRoute;
            uint alternativeOutput;

            // Try first with direct route finder
            if (bestRoute.hops == 2) {
                // For 2-hop routes, try finding alternative
                (alternativeOutput, alternativeRoute) = findBestTwoHopRoute(
                    amountIn,
                    inputToken,
                    outputToken,
                    forbidden
                );
            } else if (bestRoute.hops > 2) {
                // For multi-hop routes
                (alternativeOutput, alternativeRoute) = findBestMultiHopRoute(
                    amountIn,
                    inputToken,
                    outputToken,
                    bestRoute.hops,
                    forbidden
                );
            }

            // If we found a valid alternative route with meaningful output
            if (alternativeOutput > 0 && alternativeRoute.splitRoutes.length > 0) {
                // Check if this route is sufficiently different
                if (isSignificantlyDifferentRoute(routes, alternativeRoute, routeCount)) {
                    routes[routeCount] = alternativeRoute;
                    outputs[routeCount] = alternativeOutput;
                    routeCount++;
                }
            }
        }

        // Try some common intermediate tokens that might not be in the best route
        address[] memory commonTokens = getCommonIntermediates();
        for (uint i = 0; i < commonTokens.length && routeCount < maxPaths; i++) {
            address commonToken = commonTokens[i];

            // Skip if already used in best route
            bool alreadyUsed = false;
            for (uint j = 0; j < usedIntermediates.length; j++) {
                if (commonToken == usedIntermediates[j]) {
                    alreadyUsed = true;
                    break;
                }
            }

            if (alreadyUsed) continue;

            // Check if there's direct liquidity for both hops
            uint firstHopOutput = 0;
            address bestRouter1;
            (bestRouter1, firstHopOutput) = findBestRouterForPair(
                amountIn,
                inputToken,
                commonToken
            );

            if (firstHopOutput > 0 && bestRouter1 != address(0)) {
                uint secondHopOutput = 0;
                address bestRouter2;
                (bestRouter2, secondHopOutput) = findBestRouterForPair(
                    firstHopOutput,
                    commonToken,
                    outputToken
                );

                if (secondHopOutput > 0 && bestRouter2 != address(0)) {
                    // We found a valid path through this common token
                    TradeRoute memory newRoute;
                    newRoute.inputToken = inputToken;
                    newRoute.outputToken = outputToken;
                    newRoute.hops = 2;
                    newRoute.splitRoutes = new Split[][](2);

                    // First hop
                    newRoute.splitRoutes[0] = new Split[](1);
                    newRoute.splitRoutes[0][0] = Split({
                        router: bestRouter1,
                        percentage: 10000, // 100%
                        path: getPath(inputToken, commonToken)
                    });

                    // Second hop
                    newRoute.splitRoutes[1] = new Split[](1);
                    newRoute.splitRoutes[1][0] = Split({
                        router: bestRouter2,
                        percentage: 10000, // 100%
                        path: getPath(commonToken, outputToken)
                    });

                    // Check if this route is significantly different
                    if (isSignificantlyDifferentRoute(routes, newRoute, routeCount)) {
                        routes[routeCount] = newRoute;
                        outputs[routeCount] = secondHopOutput;
                        routeCount++;
                    }
                }
            }
        }

        // Fill any remaining slots with empty routes
        for (uint i = routeCount; i < maxPaths; i++) {
            routes[i] = TradeRoute({
                inputToken: address(0),
                outputToken: address(0),
                hops: 0,
                splitRoutes: new Split[][](0)
            });
            outputs[i] = 0;
        }

        return (routes, outputs);
    }

    // Helper function to check if a route is significantly different from existing routes
    function isSignificantlyDifferentRoute(
        TradeRoute[] memory existingRoutes, 
        TradeRoute memory newRoute,
        uint routeCount
    ) internal pure returns (bool) {
        for (uint i = 0; i < routeCount; i++) {
            TradeRoute memory existing = existingRoutes[i];

            // Skip if hops don't match - different structure means different route
            if (existing.hops != newRoute.hops) continue;

            // Count how many intermediate tokens are the same
            uint sameIntermediateCount = 0;
            uint totalIntermediates = 0;

            for (uint hop = 0; hop < existing.hops; hop++) {
                // Skip if split counts don't match
                if (existing.splitRoutes[hop].length != newRoute.splitRoutes[hop].length) continue;

                for (uint split = 0; split < existing.splitRoutes[hop].length; split++) {
                    Split memory existingSplit = existing.splitRoutes[hop][split];
                    Split memory newSplit = newRoute.splitRoutes[hop][split];

                    // Compare paths
                    if (existingSplit.path.length != newSplit.path.length) continue;

                    for (uint pathIdx = 1; pathIdx < existingSplit.path.length - 1; pathIdx++) {
                        totalIntermediates++;
                        if (existingSplit.path[pathIdx] == newSplit.path[pathIdx]) {
                            sameIntermediateCount++;
                        }
                    }
                }
            }

            // If more than 50% of intermediates are the same, routes are too similar
            if (totalIntermediates > 0 && sameIntermediateCount * 100 / totalIntermediates > 50) {
                return false;
            }
        }

        return true;
    }

    // Helper to extract all intermediate tokens from a route
    function getIntermediateTokens(TradeRoute memory route) internal pure returns (address[] memory tokens) {
        // Count total intermediate tokens
        uint totalIntermediates = 0;
        for (uint hop = 0; hop < route.hops; hop++) {
            for (uint split = 0; split < route.splitRoutes[hop].length; split++) {
                // Each path can have multiple intermediate tokens
                Split memory currentSplit = route.splitRoutes[hop][split];
                if (currentSplit.path.length > 2) {
                    totalIntermediates += currentSplit.path.length - 2;
                }
            }
        }

        tokens = new address[](totalIntermediates);
        uint tokenIdx = 0;

        // Now collect all intermediates
        for (uint hop = 0; hop < route.hops; hop++) {
            for (uint split = 0; split < route.splitRoutes[hop].length; split++) {
                Split memory currentSplit = route.splitRoutes[hop][split];

                // Skip first and last token (those are input/output for this hop)
                for (uint pathIdx = 1; pathIdx < currentSplit.path.length - 1; pathIdx++) {
                    tokens[tokenIdx] = currentSplit.path[pathIdx];
                    tokenIdx++;
                }
            }
        }

        return tokens;
    }

    // Helper for aggregating multiple parallel paths for a single swap
    function aggregateParallelPaths(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint maxPaths
    ) internal view returns (TradeRoute memory bestRoute, uint bestOutput) {
        (TradeRoute[] memory routes, uint[] memory outputs) = findParallelPaths(
            amountIn,
            inputToken,
            outputToken,
            maxPaths
        );

        // Calculate total output from all valid routes
        uint totalOutput = 0;
        uint validRouteCount = 0;

        for (uint i = 0; i < maxPaths; i++) {
            if (outputs[i] > 0 && routes[i].hops > 0) {
                totalOutput += outputs[i];
                validRouteCount++;
            }
        }

        if (validRouteCount == 0) {
            return (bestRoute, 0);
        }

        // If we only found one route, return it directly
        if (validRouteCount == 1) {
            return (routes[0], outputs[0]);
        }

        // Now we need to aggregate the routes into a single route with optimal splits

        // Sort routes by output (bubble sort for simplicity)
        for (uint i = 0; i < maxPaths; i++) {
            for (uint j = i + 1; j < maxPaths; j++) {
                if (outputs[j] > outputs[i]) {
                    // Swap outputs
                    uint tempOutput = outputs[i];
                    outputs[i] = outputs[j];
                    outputs[j] = tempOutput;

                    // Swap routes
                    TradeRoute memory tempRoute = routes[i];
                    routes[i] = routes[j];
                    routes[j] = tempRoute;
                }
            }
        }

        // Calculate proportional distribution
        uint[] memory routePercentages = new uint[](validRouteCount);
        uint totalPercentage = 0;

        for (uint i = 0; i < validRouteCount; i++) {
            routePercentages[i] = (outputs[i] * 10000) / totalOutput;
            totalPercentage += routePercentages[i];
        }

        // Adjust to ensure total is exactly 10000
        if (totalPercentage < 10000) {
            routePercentages[0] += (10000 - totalPercentage);
        }

        // Compare using best single route vs split between routes
        uint singleRouteOutput = outputs[0];
        uint potentialSplitOutput = 0;

        // Estimate split output by weighted average
        for (uint i = 0; i < validRouteCount; i++) {
            potentialSplitOutput += (outputs[i] * routePercentages[i]) / 10000;
        }

        // Add a small bonus for using multiple routes (diversification reduces slippage)
        uint diversificationBonus = potentialSplitOutput * validRouteCount * 5 / 1000; // 0.5% per route
        potentialSplitOutput += diversificationBonus;

        // If split output is significantly better, use the split
        if (potentialSplitOutput > singleRouteOutput && 
            ((potentialSplitOutput - singleRouteOutput) * 10000 / singleRouteOutput) >= SPLIT_THRESHOLD_BPS) {
            // Create an aggregated route
            TradeRoute memory aggregatedRoute;
            aggregatedRoute.inputToken = inputToken;
            aggregatedRoute.outputToken = outputToken;

            // The hops are based on the longest route
            uint maxHops = 0;
            for (uint i = 0; i < validRouteCount; i++) {
                if (routes[i].hops > maxHops) {
                    maxHops = routes[i].hops;
                }
            }

            aggregatedRoute.hops = maxHops;
            aggregatedRoute.splitRoutes = new Split[][](maxHops);

            // Initialize all hop arrays
            for (uint hop = 0; hop < maxHops; hop++) {
                aggregatedRoute.splitRoutes[hop] = new Split[](0);
            }

            // For the first hop, we'll split among all routes proportionally
            Split[] memory firstHopSplits = new Split[](validRouteCount);

            for (uint i = 0; i < validRouteCount; i++) {
                firstHopSplits[i] = routes[i].splitRoutes[0][0];
                firstHopSplits[i].percentage = routePercentages[i];
            }

            aggregatedRoute.splitRoutes[0] = firstHopSplits;

            // For remaining hops, we need to track each route separately
            // Note: This is a simplified implementation - a full implementation would be more complex

            bestRoute = aggregatedRoute;
            bestOutput = potentialSplitOutput;
        } else {
            // Just use the best single route
            bestRoute = routes[0];
            bestOutput = outputs[0];
        }

        return (bestRoute, bestOutput);
    }

    // Find the most efficient route between tokens, exploring all possible combinations
    function findOptimalRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (TradeRoute memory route, uint expectedOut) {
        // First check direct route
        uint directOutput = 0;
        Split[] memory directSplits;
        (directOutput, directSplits) = findBestSplitForHop(
            amountIn,
            inputToken,
            outputToken,
            new address[](0)
        );

        // Initialize with direct route if available
        if (directOutput > 0) {
            route.inputToken = inputToken;
            route.outputToken = outputToken;
            route.hops = 1;
            route.splitRoutes = new Split[][](1);
            route.splitRoutes[0] = directSplits;
            expectedOut = directOutput;
        }

        // Check standard multi-hop routes
        (TradeRoute memory standardRoute, uint standardOutput) = findBestRouteInternal(
            amountIn,
            inputToken,
            outputToken
        );

        if (standardOutput > expectedOut) {
            route = standardRoute;
            expectedOut = standardOutput;
        }

        // Try parallel path routing for potential better results
        (TradeRoute memory parallelRoute, uint parallelOutput) = aggregateParallelPaths(
            amountIn,
            inputToken,
            outputToken,
            3 // Try up to 3 parallel paths
        );

        if (parallelOutput > expectedOut && 
            ((parallelOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
            route = parallelRoute;
            expectedOut = parallelOutput;
        }

        // Try routing through common bridge tokens as benchmarks

        // 1. Check WETH path if neither input nor output is WETH
        if (inputToken != WETH && outputToken != WETH) {
            // First hop: input → WETH
            uint firstHopOutput = 0;
            Split[] memory firstHopSplits;
            (firstHopOutput, firstHopSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                WETH,
                new address[](0)
            );

            if (firstHopOutput > 0) {
                // Second hop: WETH → output
                uint secondHopOutput = 0;
                Split[] memory secondHopSplits;
                (secondHopOutput, secondHopSplits) = findBestSplitForHop(
                    firstHopOutput,
                    WETH,
                    outputToken,
                    new address[](0)
                );

                if (secondHopOutput > expectedOut) {
                    TradeRoute memory wethRoute;
                    wethRoute.inputToken = inputToken;
                    wethRoute.outputToken = outputToken;
                    wethRoute.hops = 2;
                    wethRoute.splitRoutes = new Split[][](2);
                    wethRoute.splitRoutes[0] = firstHopSplits;
                    wethRoute.splitRoutes[1] = secondHopSplits;

                    route = wethRoute;
                    expectedOut = secondHopOutput;
                }
            }
        }

        // 2. Check stablecoin paths
        address[] memory stablecoins = getCommonStablecoins();

        for (uint i = 0; i < stablecoins.length; i++) {
            address stablecoin = stablecoins[i];
            if (stablecoin == inputToken || stablecoin == outputToken) continue;

            // First hop: input → stablecoin
            uint firstHopOutput = 0;
            Split[] memory firstHopSplits;
            (firstHopOutput, firstHopSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                stablecoin,
                new address[](0)
            );

            if (firstHopOutput > 0) {
                // Second hop: stablecoin → output
                uint secondHopOutput = 0;
                Split[] memory secondHopSplits;
                (secondHopOutput, secondHopSplits) = findBestSplitForHop(
                    firstHopOutput,
                    stablecoin,
                    outputToken,
                    new address[](0)
                );

                if (secondHopOutput > expectedOut) {
                    TradeRoute memory stableRoute;
                    stableRoute.inputToken = inputToken;
                    stableRoute.outputToken = outputToken;
                    stableRoute.hops = 2;
                    stableRoute.splitRoutes = new Split[][](2);
                    stableRoute.splitRoutes[0] = firstHopSplits;
                    stableRoute.splitRoutes[1] = secondHopSplits;

                    route = stableRoute;
                    expectedOut = secondHopOutput;
                }
            }
        }

        // If no valid route found, return empty route
        if (expectedOut == 0) {
            route = TradeRoute({
                inputToken: inputToken,
                outputToken: outputToken,
                hops: 0,
                splitRoutes: new Split[][](0)
            });
        }

        return (route, expectedOut);
    }

    function findBestRouteInternal(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (TradeRoute memory route, uint expectedOut) {
        // Initialize the trade route
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;

        // Only check direct route if input/output tokens are valid
        if (canUseTokenInRoute(inputToken, inputToken, outputToken, false) && canUseTokenInRoute(outputToken, inputToken, outputToken, false)) {
            (uint directOutput, Split[] memory directSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                outputToken,
                new address[](0)
            );

            bestRoute.hops = 1;
            bestRoute.splitRoutes = new Split[][](1);
            bestRoute.splitRoutes[0] = directSplits;
            expectedOut = directOutput;

            uint uniquePathOutput = findBestRouterSpecificPaths(
                amountIn,
                inputToken,
                outputToken
            );

            if (uniquePathOutput > expectedOut && ((uniquePathOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                expectedOut = uniquePathOutput;
            }
        }


        for (uint hops = 2; hops <= MAX_HOPS; hops++) {
            (uint hopOutput, TradeRoute memory hopRoute) = findBestMultiHopRoute(
                amountIn,
                inputToken,
                outputToken,
                hops,
                new address[](0) 
            );

            if (hopOutput > expectedOut && ((hopOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                bestRoute = hopRoute;
                expectedOut = hopOutput;
            }
        }

        address[] memory commonStablecoins = getCommonStablecoins();
        for (uint i = 0; i < commonStablecoins.length; i++) {
            address stablecoin = commonStablecoins[i];
            if (stablecoin != inputToken && stablecoin != outputToken && isWhitelisted(stablecoin)) {
                (address bestRouterFirst, uint firstHopOutput) = findBestRouterForPair(
                    amountIn,
                    inputToken,
                    stablecoin
                );

                if (firstHopOutput > 0) {
                    (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
                        firstHopOutput,
                        stablecoin,
                        outputToken,
                        new address[](0)
                    );

                    if (secondHopOutput > expectedOut && 
                        ((secondHopOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                        TradeRoute memory newRoute;
                        newRoute.inputToken = inputToken;
                        newRoute.outputToken = outputToken;
                        newRoute.hops = 2;
                        newRoute.splitRoutes = new Split[][](2);
                        newRoute.splitRoutes[0] = new Split[](1);
                        newRoute.splitRoutes[0][0] = Split({
                            router: bestRouterFirst,
                            percentage: 10000, // 100%
                            path: getPath(inputToken, stablecoin)
                        });

                        newRoute.splitRoutes[1] = secondHopSplits;

                        bestRoute = newRoute;
                        expectedOut = secondHopOutput;
                    }
                }
            }
        }

        if (canUseTokenInRoute(inputToken, inputToken, outputToken, false) && canUseTokenInRoute(outputToken, inputToken, outputToken, false)) {
            address[] memory potentialIntermediates = getAllWhitelistedTokens();

            for (uint i = 0; i < potentialIntermediates.length && i < 20; i++) {
                address intermediateToken = potentialIntermediates[i];

                if (intermediateToken != inputToken && intermediateToken != outputToken && isWhitelisted(intermediateToken)) {
                    address[] memory pathFirstHop = getPath(inputToken, intermediateToken);

                    (address bestRouterFirstHop, uint firstHopOutput) = findBestRouterForPair(
                        amountIn,
                        inputToken,
                        intermediateToken
                    );

                    if (firstHopOutput > 0) {
                        (address bestRouterSecondHop, uint secondHopOutput) = findBestRouterForPair(
                            firstHopOutput,
                            intermediateToken,
                            outputToken
                        );

                        if (secondHopOutput > expectedOut && ((secondHopOutput - expectedOut) * 10000 / expectedOut) >= SPLIT_THRESHOLD_BPS) {
                            TradeRoute memory newRoute;
                            newRoute.inputToken = inputToken;
                            newRoute.outputToken = outputToken;
                            newRoute.hops = 2;
                            newRoute.splitRoutes = new Split[][](2);

                            // Set up first hop
                            newRoute.splitRoutes[0] = new Split[](1);
                            newRoute.splitRoutes[0][0] = Split({
                                router: bestRouterFirstHop,
                                percentage: 10000, // 100%
                                path: pathFirstHop
                            });

                            // Set up second hop
                            newRoute.splitRoutes[1] = new Split[](1);
                            newRoute.splitRoutes[1][0] = Split({
                                router: bestRouterSecondHop,
                                percentage: 10000, // 100%
                                path: getPath(intermediateToken, outputToken)
                            });

                            bestRoute = newRoute;
                            expectedOut = secondHopOutput;
                        }
                    }
                }
            }
        }

        route = bestRoute;
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

    function getPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
        // Direct path
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;

        // If either token is WETH or both are whitelisted, use direct path
        if (tokenIn == WETH || tokenOut == WETH || (isWhitelisted(tokenIn) && isWhitelisted(tokenOut))) {
            return directPath;
        }

        // For unknown tokens with no direct path, try to route through WETH
        // This helps with tokens that don't have direct pairs but have liquidity with WETH
        if (!isWhitelisted(tokenIn) || !isWhitelisted(tokenOut)) {
            // Check if direct path exists by querying the first router
            if (routers.length > 0) {
                try IUniswapV2Router02(routers[0]).getAmountsOut(1, directPath) returns (uint[] memory) {
                    // Direct path exists, return it
                    return directPath;
                } catch {
                    // Direct path doesn't exist, route through WETH
                    address[] memory wethPath = new address[](3);
                    wethPath[0] = tokenIn;
                    wethPath[1] = WETH;
                    wethPath[2] = tokenOut;
                    return wethPath;
                }
            }
        }

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
            // This handles cases like: X→Y on Router A, then split Y→Z different ways
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

                            // Note: The second part (inputToken → outputToken) 
                            // will be handled as a separate transaction in the execution
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
        for (uint i= 0; i < routers.length; i++) {
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
                address[] memory pathFirst = getPath(tokenIn, WETH);

                try IUniswapV2Router02(router).getAmountsOut(amountIn, pathFirst) returns (uint[] memory res) {
                    firstHopOutput = res[res.length - 1];
                } catch {
                    continue;
                }

                if (firstHopOutput > 0) {
                    // Try WETH -> tokenOut
                    address[] memory pathSecond = getPath(WETH, tokenOut);
                    uint finalOutput = 0;

                    try IUniswapV2Router02(router).getAmountsOut(firstHopOutput, pathSecond) returns (uint[] memory res) {
                        finalOutput = res[res.length - 1];
                    } catch {
                        continue;
                    }

                    if (finalOutput > bestAmountOut) {
                        bestAmountOut = finalOutput;
                        bestRouter = router;
                    }
                }
            }
        }
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

        for (uint i = 0; i < routers.length; i++) {
            allRouters[i] = routers[i];

            address[] memory path = getPath(tokenIn, tokenOut);
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

        for (uint i =0; i < splitRouters.length; i++) {
            if (splitRouters[i] == address(0) || splitPercentages[i] == 0) continue;

            uint routerAmountIn = (amountIn * splitPercentages[i]) / 10000;
            if (routerAmountIn == 0) continue;

            try IUniswapV2Router02(splitRouters[i]).getAmountsOut(routerAmountIn, path) returns (uint[] memory amounts) {
                totalOutput += amounts[amounts.length - 1];
            } catch {
                // Skip if router reverts
            }
        }
    }

    function optimizeSplitPercentages(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters
    ) internal view returns (uint bestOutput, uint[] memory bestPercentages) {
        uint routerCount = 0;
        uint[] memory routerOutputs = new uint[](splitRouters.length);
        uint totalPossibleOutput = 0;

        // Step 1: Collect individual router outputs and estimate liquidity
        uint[] memory routerLiquidityEstimates = new uint[](splitRouters.length);
        uint[] memory reserveRatios = new uint[](splitRouters.length);

        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0)) {
                routerCount++;
                address[] memory path = getPath(tokenIn, tokenOut);
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                    routerOutputs[i] = amounts[amounts.length - 1];
                    totalPossibleOutput += routerOutputs[i];

                    // Estimate liquidity by getting the pair and checking reserves
                    try IUniswapV2Factory(IUniswapV2Router02(splitRouters[i]).factory()).getPair(path[0], path[path.length-1]) returns (address pair) {
                        if (pair != address(0)) {
                            try IUniswapV2Pair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
                                address token0 = IUniswapV2Pair(pair).token0();
                                uint reserveIn;
                                uint reserveOut;

                                if (path[0] == token0) {
                                    reserveIn = reserve0;
                                    reserveOut = reserve1;
                                } else {
                                    reserveIn = reserve1;
                                    reserveOut = reserve0;
                                }

                                // Estimate liquidity as geometric mean of reserves
                                routerLiquidityEstimates[i] = sqrt(reserveIn * reserveOut);

                                // Calculate reserve ratio (10000 = balanced)
                                if (reserveOut > 0) {
                                    reserveRatios[i] = (reserveIn * 10000) / reserveOut;
                                } else {
                                    reserveRatios[i] = 0;
                                }
                            } catch {
                                routerLiquidityEstimates[i] = 0;
                                reserveRatios[i] = 10000; // Default to balanced
                            }
                        }
                    } catch {
                        routerLiquidityEstimates[i] = 0;
                        reserveRatios[i] = 10000; // Default to balanced
                    }
                } catch {
                    routerOutputs[i] = 0;
                    routerLiquidityEstimates[i] = 0;
                    reserveRatios[i] = 10000;
                }
            }
        }

        if (routerCount == 0) return (0, new uint[](0));

        // Step 2: Initialize best percentages based on weighted factors
        bestPercentages = new uint[](splitRouters.length);

        // Consider both output amounts and liquidity for initial distribution
        uint totalWeight = 0;
        uint[] memory routerWeights = new uint[](splitRouters.length);

        for (uint i = 0; i < splitRouters.length; i++) {
            if (routerOutputs[i] > 0) {
                // Calculate weights based on outputs and liquidity
                uint outputWeight = routerOutputs[i] * 7; // Output has 70% weight
                uint liquidityWeight = 0;

                if (routerLiquidityEstimates[i] > 0) {
                    liquidityWeight = routerLiquidityEstimates[i] * 3; // Liquidity has 30% weight
                }

                // Add a small bonus for balanced reserves
                uint reserveBonus = 0;
                if (reserveRatios[i] > 0 && reserveRatios[i] <= 20000) { // Within reasonable balance (0.5x to 2x)
                    // Calculate how far from perfect balance (10000)
                    uint balanceDeviation = reserveRatios[i] > 10000 ? 
                                          (reserveRatios[i] - 10000) : 
                                          (10000 - reserveRatios[i]);

                    // Less deviation = higher bonus
                    reserveBonus = (10000 - balanceDeviation) / 100; // Up to 100 bonus points
                }

                routerWeights[i] = outputWeight + liquidityWeight + reserveBonus;
                totalWeight += routerWeights[i];
            }
        }

        if (totalWeight > 0) {
            // Distribute based on weights
            uint totalPercentage = 0;
            for (uint i = 0; i < splitRouters.length; i++) {
                if (routerWeights[i] > 0) {
                    bestPercentages[i] = (routerWeights[i] * 10000) / totalWeight;
                    totalPercentage += bestPercentages[i];
                }
            }

            // Ensure percentages sum to 10000 (100%)
            if (totalPercentage < 10000) {
                // Find router with highest output to give the remainder
                uint maxOutput = 0;
                uint maxIndex = 0;
                for (uint i = 0; i < routerOutputs.length; i++) {
                    if (routerOutputs[i] > maxOutput) {
                        maxOutput = routerOutputs[i];
                        maxIndex = i;
                    }
                }
                bestPercentages[maxIndex] += (10000 - totalPercentage);
            }
        } else {
            // Fallback to equal distribution if we couldn't calculate weights
            for (uint i = 0; i < splitRouters.length && splitRouters[i] != address(0); i++) {
                bestPercentages[i] = 10000 / routerCount;
            }
        }

        // Calculate initial output based on our weighted distribution
        bestOutput = calculateSplitOutput(
            amountIn,
            tokenIn,
            tokenOut,
            splitRouters,
            bestPercentages
        );

        // Step 3: Find active routers and their indices
        uint activeRouterCount = 0;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0) && routerOutputs[i] > 0) {
                activeRouterCount++;
            }
        }

        if (activeRouterCount == 0) return (0, new uint[](0));

        address[] memory activeRouters = new address[](activeRouterCount);
        uint[] memory activeIndices = new uint[](activeRouterCount);
        uint[] memory activeOutputs = new uint[](activeRouterCount);
        uint[] memory activeLiquidity = new uint[](activeRouterCount);

        uint activeIdx = 0;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0) && routerOutputs[i] > 0) {
                activeRouters[activeIdx] = splitRouters[i];
                activeIndices[activeIdx] = i;
                activeOutputs[activeIdx] = routerOutputs[i];
                activeLiquidity[activeIdx] = routerLiquidityEstimates[i];
                activeIdx++;
            }
        }

        // Step 4: Generate and test dynamic distributions
        if (activeRouterCount >= 1) {
            // Test single router allocations
            for (uint i = 0; i < activeRouterCount; i++) {
                uint[] memory singleDistribution = new uint[](splitRouters.length);
                singleDistribution[activeIndices[i]] = 10000;

                uint output = calculateSplitOutput(
                    amountIn,
                    tokenIn,
                    tokenOut,
                    splitRouters,
                    singleDistribution
                );

                if (output > bestOutput) {
                    bestOutput = output;
                    bestPercentages = singleDistribution;
                }
            }
        }

        if (activeRouterCount >= 2) {
            // Dynamic step size based on router count and amount
            uint stepSize = 1000; // 10% steps default

            // Adjust step size based on input amount and token decimals
            uint8 decimalsIn;
            try IERC20(tokenIn).decimals() returns (uint8 dec) {
                decimalsIn = dec;
            } catch {
                decimalsIn = 18;
            }

            // For large amounts, use finer steps
            if (amountIn >= 10 ** (decimalsIn + 1)) { // If amount > 10 tokens
                stepSize = 500; // 5%
            }

            // For very large amounts, use even finer steps
            if (amountIn >= 10 ** (decimalsIn + 2)) { // If amount > 100 tokens
                stepSize = 250; // 2.5%
            }

            // If too many routers, use coarser steps to save gas
            if (activeRouterCount > 3) {
                stepSize = stepSize * 2;
            }

            // Generate two-router combinations with dynamic ratios
            for (uint i = 0; i < activeRouterCount; i++) {
                for (uint j = i + 1; j < activeRouterCount; j++) {
                    // Test various proportions between the two routers
                    for (uint percent = 0; percent <= 10000; percent += stepSize) {
                        uint[] memory distribution = new uint[](splitRouters.length);
                        distribution[activeIndices[i]] = percent;
                        distribution[activeIndices[j]] = 10000 - percent;

                        uint output = calculateSplitOutput(
                            amountIn,
                            tokenIn,
                            tokenOut,
                            splitRouters,
                            distribution
                        );

                        if (output > bestOutput) {
                            bestOutput = output;
                            bestPercentages = distribution;
                        }
                    }

                    // Try additional precision around the current best
                    uint currentBest = 0;
                    for (uint k = 0; k < bestPercentages.length; k++) {
                        if (k == activeIndices[i]) {
                            currentBest = bestPercentages[k];
                            break;
                        }
                    }

                    // Fine-tune around current best (if it's between i and j)
                    if (currentBest > 0 && currentBest < 10000) {
                        for (int delta = -int(stepSize/2); delta <= int(stepSize/2); delta += int(stepSize/4)) {
                            if (delta == 0) continue; // Skip the exact current best

                            int newPercent = int(currentBest) + delta;
                            if (newPercent <= 0 || newPercent >= 10000) continue;

                            uint[] memory refinedDistribution = new uint[](splitRouters.length);
                            refinedDistribution[activeIndices[i]] = uint(newPercent);
                            refinedDistribution[activeIndices[j]] = 10000 - uint(newPercent);

                            uint refinedOutput = calculateSplitOutput(
                                amountIn,
                                tokenIn,
                                tokenOut,
                                splitRouters,
                                refinedDistribution
                            );

                            if (refinedOutput > bestOutput) {
                                bestOutput = refinedOutput;
                                bestPercentages = refinedDistribution;
                            }
                        }
                    }
                }
            }

            // Try triple router combinations if there are enough active routers
            if (activeRouterCount >= 3) {
                // Try intelligently selected combinations based on previous results

                // Sort active routers by their outputs (bubble sort)
                for (uint i = 0; i < activeRouterCount; i++) {
                    for (uint j = i + 1; j < activeRouterCount; j++) {
                        if (activeOutputs[j] > activeOutputs[i]) {
                            // Swap outputs
                            uint tempOutput = activeOutputs[i];
                            activeOutputs[i] = activeOutputs[j];
                            activeOutputs[j] = tempOutput;

                            // Swap liquidity
                            uint tempLiquidity = activeLiquidity[i];
                            activeLiquidity[i] = activeLiquidity[j];
                            activeLiquidity[j] = tempLiquidity;

                            // Swap indices
                            uint tempIndex = activeIndices[i];
                            activeIndices[i] = activeIndices[j];
                            activeIndices[j] = tempIndex;

                            // Swap routers
                            address tempRouter = activeRouters[i];
                            activeRouters[i] = activeRouters[j];
                            activeRouters[j] = tempRouter;
                        }
                    }
                }

                // Combinations using the top 3 routers
                uint totalTopOutput = activeOutputs[0] + activeOutputs[1] + activeOutputs[2];

                // Skip if no output
                if (totalTopOutput > 0) {
                    // Try some intelligent distribution patterns
                    uint[] memory tripleSplitPatterns = new uint[](6);
                    tripleSplitPatterns[0] = 6000; // 60/30/10
                    tripleSplitPatterns[1] = 5000; // 50/30/20
                    tripleSplitPatterns[2] = 4000; // 40/40/20
                    tripleSplitPatterns[3] = 3333; // 33/33/33
                    tripleSplitPatterns[4] = 7000; // 70/20/10
                    tripleSplitPatterns[5] = 8000; // 80/15/5

                    for (uint i = 0; i < tripleSplitPatterns.length; i++) {
                        uint firstPercent = tripleSplitPatterns[i];
                        uint remainingPercent = 10000 - firstPercent;

                        // Calculate second router's percent of remaining
                        uint secondPercentOfRemaining = 6667; // 2/3 of remainder
                        if (i == 2) secondPercentOfRemaining = 5000; // 50% for pattern 2
                        if (i == 3) secondPercentOfRemaining = 5000; // 50% for pattern 3
                        if (i == 4) secondPercentOfRemaining = 6667; // 2/3 for pattern 4
                        if (i == 5) secondPercentOfRemaining = 7500; // 75% for pattern 5

                        uint secondPercent = (remainingPercent * secondPercentOfRemaining) / 10000;
                        uint thirdPercent = remainingPercent - secondPercent;

                        uint[] memory tripleDistribution = new uint[](splitRouters.length);
                        tripleDistribution[activeIndices[0]] = firstPercent;
                        tripleDistribution[activeIndices[1]] = secondPercent;
                        tripleDistribution[activeIndices[2]] = thirdPercent;

                        uint tripleOutput = calculateSplitOutput(
                            amountIn,
                            tokenIn,
                            tokenOut,
                            splitRouters,
                            tripleDistribution
                        );

                        if (tripleOutput > bestOutput) {
                            bestOutput = tripleOutput;
                            bestPercentages = tripleDistribution;
                        }
                    }

                    // Also try distributions based on actual outputs
                    uint[] memory outputBasedDistribution = new uint[](splitRouters.length);

                    // Linear distribution based on output
                    outputBasedDistribution[activeIndices[0]] = (activeOutputs[0] * 10000) / totalTopOutput;
                    outputBasedDistribution[activeIndices[1]] = (activeOutputs[1] * 10000) / totalTopOutput;
                    outputBasedDistribution[activeIndices[2]] = 10000 - outputBasedDistribution[activeIndices[0]] - outputBasedDistribution[activeIndices[1]];

                    uint outputBasedResult = calculateSplitOutput(
                        amountIn,
                        tokenIn,
                        tokenOut,
                        splitRouters,
                        outputBasedDistribution
                    );

                    if (outputBasedResult > bestOutput) {
                        bestOutput = outputBasedResult;
                        bestPercentages = outputBasedDistribution;
                    }

                    // Exponential distribution (square of outputs) for better concentration
                    uint totalSquared = (activeOutputs[0] * activeOutputs[0]) + 
                                      (activeOutputs[1] * activeOutputs[0]) + 
                                      (activeOutputs[2] * activeOutputs[2]);

                    if (totalSquared > 0) {
                        uint[] memory expDistribution = new uint[](splitRouters.length);
                        expDistribution[activeIndices[0]] = (activeOutputs[0] * activeOutputs[0] * 10000) / totalSquared;
                        expDistribution[activeIndices[1]] = (activeOutputs[1] * activeOutputs[1] * 10000) / totalSquared;
                        expDistribution[activeIndices[2]] = 10000 - expDistribution[activeIndices[0]] - expDistribution[activeIndices[1]];

                        uint expOutput = calculateSplitOutput(
                            amountIn,
                            tokenIn,
                            tokenOut,
                            splitRouters,
                            expDistribution
                        );

                        if (expOutput > bestOutput) {
                            bestOutput = expOutput;
                            bestPercentages = expDistribution;
                        }
                    }

                    // Liquidity-weighted distribution for slippage protection
                    uint totalLiquidity = activeLiquidity[0] + activeLiquidity[1] + activeLiquidity[2];

                    if (totalLiquidity > 0) {
                        uint[] memory liqDistribution = new uint[](splitRouters.length);
                        liqDistribution[activeIndices[0]] = (activeLiquidity[0] * 10000) / totalLiquidity;
                        liqDistribution[activeIndices[1]] = (activeLiquidity[1] * 10000) / totalLiquidity;
                        liqDistribution[activeIndices[2]] = 10000 - liqDistribution[activeIndices[0]] - liqDistribution[activeIndices[1]];

                        uint liqOutput = calculateSplitOutput(
                            amountIn,
                            tokenIn,
                            tokenOut,
                            splitRouters,
                            liqDistribution
                        );

                        // Use liquidity-based distribution if it's close enough (within 1%)
                        if (liqOutput > 0 && bestOutput > 0 && 
                            ((bestOutput - liqOutput) * 10000 / bestOutput) <= 100) {
                            bestOutput = liqOutput;
                            bestPercentages = liqDistribution;
                        }
                    }
                }
            }
        }

        // Step 5: Advanced optimization - Try gradient descent
        if (activeRouterCount >= 2) {
            // Copy current best percentages
            uint[] memory gradientPercentages = new uint[](splitRouters.length);
            for (uint i = 0; i < splitRouters.length; i++) {
                gradientPercentages[i] = bestPercentages[i];
            }

            // Iteratively improve by small adjustments
            bool improved = true;
            uint iterations = 0;
            uint maxIterations = 5; // Limit iterations for gas efficiency

            while (improved && iterations < maxIterations) {
                improved = false;
                iterations++;

                // Try shifting small amounts between each pair of routers
                for (uint i = 0; i < activeRouterCount; i++) {
                    for (uint j = 0; j < activeRouterCount; j++) {
                        if (i == j) continue;

                        uint idx1 = activeIndices[i];
                        uint idx2 = activeIndices[j];

                        // Try multiple step sizes, smaller with each iteration
                        uint stepSize = 250 / (iterations); // Gradually reduce step size
                        if (stepSize < 50) stepSize = 50; // Minimum step size

                        if (gradientPercentages[idx2] >= stepSize) {
                            // Try shifting some percentage from j to i
                            uint[] memory testPercentages = new uint[](splitRouters.length);
                            for (uint k = 0; k < splitRouters.length; k++) {
                                testPercentages[k] = gradientPercentages[k];
                            }

                            testPercentages[idx1] += stepSize;
                            testPercentages[idx2] -= stepSize;

                            uint testOutput = calculateSplitOutput(
                                amountIn,
                                tokenIn,
                                tokenOut,
                                splitRouters,
                                testPercentages
                            );

                            if (testOutput > bestOutput) {
                                bestOutput = testOutput;
                                improved = true;

                                // Update both current working copy and best percentages
                                for (uint k = 0; k < splitRouters.length; k++) {
                                    bestPercentages[k] = testPercentages[k];
                                    gradientPercentages[k] = testPercentages[k];
                                }
                            }
                        }
                    }
                }
            }
        }

        // Ensure we have no zeros in the middle of distribution
        bool foundNonZero = false;
        uint lastNonZeroIdx = 0;

        for (uint i = 0; i < bestPercentages.length; i++) {
            if (bestPercentages[i] > 0) {
                foundNonZero = true;
                lastNonZeroIdx = i;
            } else if (foundNonZero && i < bestPercentages.length - 1 && bestPercentages[i+1] > 0) {
                // Found a zero with non-zeros on both sides - move this percentage to last non-zero
                bestPercentages[lastNonZeroIdx] += bestPercentages[i+1];
                bestPercentages[i+1] = 0;
            }
        }

        // Final check: balanced distribution
        uint activeCount = 0;
        for (uint i = 0; i < bestPercentages.length; i++) {
            if (bestPercentages[i] > 0) activeCount++;
        }

        if (activeCount >= 2) {
            // Calculate balanced distribution
            uint[] memory balancedDistribution = new uint[](splitRouters.length);
            uint perRouterPercent = 10000 / activeCount;

            uint totalAllocated = 0;
            uint lastActiveIdx = 0;

            for (uint i = 0; i < splitRouters.length; i++) {
                if (bestPercentages[i] > 0) {
                    balancedDistribution[i] = perRouterPercent;
                    totalAllocated += perRouterPercent;
                    lastActiveIdx = i;
                }
            }

            // Give remainder to the last active router
            if (totalAllocated < 10000) {
                balancedDistribution[lastActiveIdx] += (10000 - totalAllocated);
            }

            uint balancedOutput = calculateSplitOutput(
                amountIn,
                tokenIn,
                tokenOut,
                splitRouters,
                balancedDistribution
            );

            // Use balanced distribution if it's close to optimal
            if (balancedOutput > 0 && bestOutput > 0) {
                uint diff = 0;
                if (bestOutput > balancedOutput) {
                    diff = ((bestOutput - balancedOutput) * 10000) / bestOutput;
                }

                // If balanced distribution is within 1% of best, use it for better slippage protection
                if (diff < 100) {
                    bestOutput = balancedOutput;
                    bestPercentages = balancedDistribution;
                }
            }
        }

        return (bestOutput, bestPercentages);
    }

    // Helper function for calculating square root (for geometric mean of reserves)
    function sqrt(uint x) internal pure returns (uint y) {
        if (x == 0) return 0;
        else if (x <= 3) return 1;

        uint z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
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

        emit SwapExecuted(msg.sender, amountIn, amountOut);
    }

    receive() external payable {}
}