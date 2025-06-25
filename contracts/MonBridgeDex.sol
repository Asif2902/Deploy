
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
    uint public constant MAX_SPLITS_PER_HOP = 8;

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
        require(amountIn > 0, "Amount must be greater than 0");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(inputToken != outputToken, "Input and output tokens must be different");
        require(routers.length > 0, "No routers configured");

        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        expectedOut = 0;
        
        // Phase 1: Ultra-precise direct path optimization
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
            expectedOut = directOutput;
        }
        
        // Phase 2: Advanced arbitrage detection and complex path finding
        address[] memory primeIntermediates = getPrimeIntermediateTokens(inputToken, outputToken);
        
        // Phase 3: Multi-dimensional greedy exploration with arbitrage
        for (uint hopCount = 2; hopCount <= MAX_HOPS; hopCount++) {
            // Standard greedy multi-hop
            (uint hopOutput, TradeRoute memory hopRoute) = findGreedyMultiHopRoute(
                amountIn,
                inputToken,
                outputToken,
                hopCount,
                primeIntermediates,
                expectedOut
            );
            
            if (hopOutput > expectedOut) {
                bestRoute = hopRoute;
                expectedOut = hopOutput;
            }
            
            // Advanced arbitrage triangular routes
            (uint arbOutput, TradeRoute memory arbRoute) = findArbitrageTriangularRoute(
                amountIn,
                inputToken,
                outputToken,
                hopCount,
                primeIntermediates,
                expectedOut
            );
            
            if (arbOutput > expectedOut) {
                bestRoute = arbRoute;
                expectedOut = arbOutput;
            }
            
            // Complex circular arbitrage paths
            (uint circularOutput, TradeRoute memory circularRoute) = findCircularArbitrageRoute(
                amountIn,
                inputToken,
                outputToken,
                hopCount,
                primeIntermediates,
                expectedOut
            );
            
            if (circularOutput > expectedOut) {
                bestRoute = circularRoute;
                expectedOut = circularOutput;
            }
            
            // Cross-router arbitrage exploitation
            (uint crossOutput, TradeRoute memory crossRoute) = findCrossRouterArbitrageRoute(
                amountIn,
                inputToken,
                outputToken,
                hopCount,
                expectedOut
            );
            
            if (crossOutput > expectedOut) {
                bestRoute = crossRoute;
                expectedOut = crossOutput;
            }
            
            // Early termination with higher threshold
            if (expectedOut > amountIn * 15 / 10) break; // 50% gain threshold
        }
        
        // Phase 4: Final optimization - try complex split combinations
        (uint complexOutput, TradeRoute memory complexRoute) = findComplexSplitCombinations(
            amountIn,
            inputToken,
            outputToken,
            expectedOut
        );
        
        if (complexOutput > expectedOut) {
            bestRoute = complexRoute;
            expectedOut = complexOutput;
        }
        
        // Ensure valid route
        if (expectedOut > 0 && bestRoute.hops > 0) {
            route = bestRoute;
        } else {
            route = TradeRoute({
                inputToken: inputToken,
                outputToken: outputToken,
                hops: 0,
                splitRoutes: new Split[][](0)
            });
            expectedOut = 0;
        }
    }
    
    function getPrimeIntermediateTokens(address inputToken, address outputToken) internal view returns (address[] memory) {
        address[] memory allIntermediates = getAllWhitelistedTokens();
        address[] memory ranked = new address[](allIntermediates.length + 2);
        uint[] memory scores = new uint[](allIntermediates.length + 2);
        uint validCount = 0;
        
        // Score intermediates by liquidity and connectivity
        for (uint i = 0; i < allIntermediates.length; i++) {
            address intermediate = allIntermediates[i];
            if (intermediate == address(0) || intermediate == inputToken || intermediate == outputToken) continue;
            
            // Quick liquidity analysis
            uint inputLiquidity = analyzeLiquidityDepth(inputToken, intermediate);
            uint outputLiquidity = analyzeLiquidityDepth(intermediate, outputToken);
            
            if (inputLiquidity > 0 && outputLiquidity > 0) {
                scores[validCount] = sqrt(inputLiquidity * outputLiquidity);
                ranked[validCount] = intermediate;
                validCount++;
            }
        }
        
        // Add WETH and common stables at high priority
        if (inputToken != WETH && outputToken != WETH) {
            ranked[validCount] = WETH;
            scores[validCount] = type(uint).max; // Highest priority
            validCount++;
        }
        
        address[] memory stables = getCommonStablecoins();
        for (uint i = 0; i < stables.length && validCount < ranked.length; i++) {
            if (stables[i] != address(0) && stables[i] != inputToken && stables[i] != outputToken && stables[i] != WETH) {
                ranked[validCount] = stables[i];
                scores[validCount] = type(uint).max - 1; // Second priority
                validCount++;
            }
        }
        
        // Quick sort by score (top 6 for gas efficiency)
        for (uint i = 0; i < validCount && i < 6; i++) {
            for (uint j = i + 1; j < validCount; j++) {
                if (scores[j] > scores[i]) {
                    uint tempScore = scores[i];
                    scores[i] = scores[j];
                    scores[j] = tempScore;
                    
                    address tempAddr = ranked[i];
                    ranked[i] = ranked[j];
                    ranked[j] = tempAddr;
                }
            }
        }
        
        // Return top intermediates
        uint returnCount = validCount > 6 ? 6 : validCount;
        address[] memory result = new address[](returnCount);
        for (uint i = 0; i < returnCount; i++) {
            result[i] = ranked[i];
        }
        
        return result;
    }
    
    function findGreedyMultiHopRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hopCount,
        address[] memory primeIntermediates,
        uint currentBest
    ) internal view returns (uint bestOutput, TradeRoute memory bestRoute) {
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = hopCount;
        bestRoute.splitRoutes = new Split[][](hopCount);
        bestOutput = 0;
        
        // Greedy approach: build route hop by hop selecting best intermediate
        address currentToken = inputToken;
        uint currentAmount = amountIn;
        Split[][] memory currentRoute = new Split[][](hopCount);
        
        for (uint hop = 0; hop < hopCount; hop++) {
            address targetToken = (hop == hopCount - 1) ? outputToken : address(0);
            uint bestHopOutput = 0;
            Split[] memory bestHopSplits;
            address bestIntermediate = address(0);
            
            if (hop == hopCount - 1) {
                // Final hop - go to output token
                (bestHopOutput, bestHopSplits) = findBestSplitForHop(
                    currentAmount,
                    currentToken,
                    outputToken,
                    new address[](0)
                );
            } else {
                // Intermediate hop - find best next token
                for (uint i = 0; i < primeIntermediates.length; i++) {
                    address candidate = primeIntermediates[i];
                    if (candidate == address(0) || candidate == currentToken) continue;
                    
                    (uint hopOutput, Split[] memory hopSplits) = findBestSplitForHop(
                        currentAmount,
                        currentToken,
                        candidate,
                        new address[](0)
                    );
                    
                    // Estimate remaining route value using heuristic
                    uint estimatedFinalOutput = estimateRemainingValue(
                        hopOutput,
                        candidate,
                        outputToken,
                        hopCount - hop - 1
                    );
                    
                    if (estimatedFinalOutput > bestHopOutput) {
                        bestHopOutput = hopOutput;
                        bestHopSplits = hopSplits;
                        bestIntermediate = candidate;
                    }
                }
            }
            
            if (bestHopOutput == 0) break; // Route not viable
            
            currentRoute[hop] = bestHopSplits;
            currentAmount = bestHopOutput;
            currentToken = (hop == hopCount - 1) ? outputToken : bestIntermediate;
            
            // Early termination if route won't beat current best
            if (hop < hopCount - 1) {
                uint projectedFinal = estimateRemainingValue(currentAmount, currentToken, outputToken, hopCount - hop - 1);
                if (projectedFinal <= currentBest) break;
            }
        }
        
        if (currentToken == outputToken && currentAmount > bestOutput) {
            bestOutput = currentAmount;
            bestRoute.splitRoutes = currentRoute;
        }
        
        return (bestOutput, bestRoute);
    }
    
    function estimateRemainingValue(
        uint amount,
        address fromToken,
        address toToken,
        uint remainingHops
    ) internal view returns (uint estimatedOutput) {
        if (remainingHops == 0) return amount;
        if (fromToken == toToken) return amount;
        
        // Enhanced estimate using best path with arbitrage detection
        (address bestRouter, uint directOutput) = findBestRouterForPair(amount, fromToken, toToken);
        if (directOutput > 0) {
            // Apply arbitrage multiplier based on remaining hops
            uint arbitrageMultiplier = 10000 + (remainingHops * 25); // Up to 2% per hop
            return (directOutput * arbitrageMultiplier) / 10000;
        }
        
        // Multi-hop estimate through WETH with arbitrage
        if (fromToken != WETH && toToken != WETH) {
            (, uint toWethOutput) = findBestRouterForPair(amount, fromToken, WETH);
            if (toWethOutput > 0) {
                (, uint finalOutput) = findBestRouterForPair(toWethOutput, WETH, toToken);
                if (finalOutput > 0) {
                    uint arbitrageMultiplier = 10000 + (remainingHops * 30); // Higher for WETH routes
                    return (finalOutput * arbitrageMultiplier) / 10000;
                }
            }
        }
        
        // Conservative fallback with potential upside
        return (amount * 8) / 10; // More optimistic than 50%
    }
    
    function findArbitrageTriangularRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hopCount,
        address[] memory primeIntermediates,
        uint currentBest
    ) internal view returns (uint bestOutput, TradeRoute memory bestRoute) {
        if (hopCount < 3) return (0, bestRoute);
        
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = hopCount;
        bestRoute.splitRoutes = new Split[][](hopCount);
        bestOutput = 0;
        
        // Triangular arbitrage: A → B → C → A → Output
        for (uint i = 0; i < primeIntermediates.length; i++) {
            for (uint j = 0; j < primeIntermediates.length; j++) {
                if (i == j) continue;
                
                address tokenB = primeIntermediates[i];
                address tokenC = primeIntermediates[j];
                
                if (tokenB == address(0) || tokenC == address(0)) continue;
                if (tokenB == inputToken || tokenB == outputToken) continue;
                if (tokenC == inputToken || tokenC == outputToken) continue;
                
                // Path: input → B → C → input → output
                uint currentAmount = amountIn;
                Split[][] memory routeSplits = new Split[][](hopCount);
                bool validPath = true;
                
                // Hop 1: input → B
                (uint hop1Output, Split[] memory hop1Splits) = findBestSplitForHop(
                    currentAmount, inputToken, tokenB, new address[](0)
                );
                if (hop1Output == 0) continue;
                routeSplits[0] = hop1Splits;
                currentAmount = hop1Output;
                
                // Hop 2: B → C
                (uint hop2Output, Split[] memory hop2Splits) = findBestSplitForHop(
                    currentAmount, tokenB, tokenC, new address[](0)
                );
                if (hop2Output == 0) continue;
                routeSplits[1] = hop2Splits;
                currentAmount = hop2Output;
                
                // Hop 3: C → input (arbitrage back)
                (uint hop3Output, Split[] memory hop3Splits) = findBestSplitForHop(
                    currentAmount, tokenC, inputToken, new address[](0)
                );
                if (hop3Output <= amountIn) continue; // Must be profitable
                routeSplits[2] = hop3Splits;
                currentAmount = hop3Output;
                
                // Remaining hops to output
                for (uint k = 3; k < hopCount; k++) {
                    address nextToken = (k == hopCount - 1) ? outputToken : primeIntermediates[k % primeIntermediates.length];
                    if (nextToken == address(0)) {
                        validPath = false;
                        break;
                    }
                    
                    (uint hopOutput, Split[] memory hopSplits) = findBestSplitForHop(
                        currentAmount, 
                        (k == 3) ? inputToken : primeIntermediates[(k-1) % primeIntermediates.length],
                        nextToken,
                        new address[](0)
                    );
                    
                    if (hopOutput == 0) {
                        validPath = false;
                        break;
                    }
                    
                    routeSplits[k] = hopSplits;
                    currentAmount = hopOutput;
                }
                
                if (validPath && currentAmount > bestOutput && currentAmount > currentBest) {
                    bestOutput = currentAmount;
                    bestRoute.splitRoutes = routeSplits;
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    function findCircularArbitrageRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hopCount,
        address[] memory primeIntermediates,
        uint currentBest
    ) internal view returns (uint bestOutput, TradeRoute memory bestRoute) {
        if (hopCount < 4) return (0, bestRoute);
        
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = hopCount;
        bestRoute.splitRoutes = new Split[][](hopCount);
        bestOutput = 0;
        
        // Circular arbitrage with multiple intermediate tokens
        for (uint i = 0; i < primeIntermediates.length; i++) {
            address intermediate1 = primeIntermediates[i];
            if (intermediate1 == address(0) || intermediate1 == inputToken || intermediate1 == outputToken) continue;
            
            for (uint j = 0; j < primeIntermediates.length; j++) {
                if (i == j) continue;
                address intermediate2 = primeIntermediates[j];
                if (intermediate2 == address(0) || intermediate2 == inputToken || intermediate2 == outputToken) continue;
                
                // Split input into two paths and recombine
                uint split1Amount = (amountIn * 6000) / 10000; // 60%
                uint split2Amount = amountIn - split1Amount;     // 40%
                
                // Path 1: input → intermediate1 → output
                (uint path1Step1, Split[] memory path1Step1Splits) = findBestSplitForHop(
                    split1Amount, inputToken, intermediate1, new address[](0)
                );
                if (path1Step1 == 0) continue;
                
                (uint path1Final, Split[] memory path1FinalSplits) = findBestSplitForHop(
                    path1Step1, intermediate1, outputToken, new address[](0)
                );
                if (path1Final == 0) continue;
                
                // Path 2: input → intermediate2 → intermediate1 → output
                (uint path2Step1, Split[] memory path2Step1Splits) = findBestSplitForHop(
                    split2Amount, inputToken, intermediate2, new address[](0)
                );
                if (path2Step1 == 0) continue;
                
                (uint path2Step2, Split[] memory path2Step2Splits) = findBestSplitForHop(
                    path2Step1, intermediate2, intermediate1, new address[](0)
                );
                if (path2Step2 == 0) continue;
                
                (uint path2Final, Split[] memory path2FinalSplits) = findBestSplitForHop(
                    path2Step2, intermediate1, outputToken, new address[](0)
                );
                if (path2Final == 0) continue;
                
                uint totalOutput = path1Final + path2Final;
                
                if (totalOutput > bestOutput && totalOutput > currentBest) {
                    bestOutput = totalOutput;
                    
                    // Construct route with mixed splits
                    Split[][] memory routeSplits = new Split[][](hopCount);
                    
                    // First hop: split between two paths
                    routeSplits[0] = new Split[](2);
                    routeSplits[0][0] = Split({
                        router: path1Step1Splits[0].router,
                        percentage: 6000,
                        path: path1Step1Splits[0].path
                    });
                    routeSplits[0][1] = Split({
                        router: path2Step1Splits[0].router,
                        percentage: 4000,
                        path: path2Step1Splits[0].path
                    });
                    
                    // Fill remaining hops
                    for (uint k = 1; k < hopCount; k++) {
                        if (k == hopCount - 1) {
                            // Final hop combines both paths
                            routeSplits[k] = new Split[](2);
                            routeSplits[k][0] = path1FinalSplits[0];
                            routeSplits[k][1] = path2FinalSplits[0];
                        } else {
                            // Middle hops
                            routeSplits[k] = path2Step2Splits;
                        }
                    }
                    
                    bestRoute.splitRoutes = routeSplits;
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    function findCrossRouterArbitrageRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hopCount,
        uint currentBest
    ) internal view returns (uint bestOutput, TradeRoute memory bestRoute) {
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = hopCount;
        bestRoute.splitRoutes = new Split[][](hopCount);
        bestOutput = 0;
        
        // Cross-router arbitrage: use different routers for each hop to exploit price differences
        address[] memory intermediates = getPrimeIntermediateTokens(inputToken, outputToken);
        
        for (uint routerIdx1 = 0; routerIdx1 < routers.length; routerIdx1++) {
            for (uint routerIdx2 = 0; routerIdx2 < routers.length; routerIdx2++) {
                if (routerIdx1 == routerIdx2) continue;
                
                address router1 = routers[routerIdx1];
                address router2 = routers[routerIdx2];
                if (router1 == address(0) || router2 == address(0)) continue;
                
                for (uint i = 0; i < intermediates.length; i++) {
                    address intermediate = intermediates[i];
                    if (intermediate == address(0)) continue;
                    
                    // Exploit price difference between routers
                    address[] memory path1 = getPath(inputToken, intermediate);
                    address[] memory path2 = getPath(intermediate, outputToken);
                    
                    uint hop1Output = 0;
                    try IUniswapV2Router02(router1).getAmountsOut(amountIn, path1) returns (uint[] memory res) {
                        hop1Output = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    if (hop1Output == 0) continue;
                    
                    uint hop2Output = 0;
                    try IUniswapV2Router02(router2).getAmountsOut(hop1Output, path2) returns (uint[] memory res) {
                        hop2Output = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    // Check reverse path for comparison
                    uint reverseHop1 = 0;
                    try IUniswapV2Router02(router2).getAmountsOut(amountIn, path1) returns (uint[] memory res) {
                        reverseHop1 = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    uint reverseHop2 = 0;
                    try IUniswapV2Router02(router1).getAmountsOut(reverseHop1, path2) returns (uint[] memory res) {
                        reverseHop2 = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    uint finalOutput = hop2Output > reverseHop2 ? hop2Output : reverseHop2;
                    bool useReverse = reverseHop2 > hop2Output;
                    
                    if (finalOutput > bestOutput && finalOutput > currentBest) {
                        bestOutput = finalOutput;
                        
                        Split[][] memory routeSplits = new Split[][](2);
                        
                        routeSplits[0] = new Split[](1);
                        routeSplits[0][0] = Split({
                            router: useReverse ? router2 : router1,
                            percentage: 10000,
                            path: path1
                        });
                        
                        routeSplits[1] = new Split[](1);
                        routeSplits[1][0] = Split({
                            router: useReverse ? router1 : router2,
                            percentage: 10000,
                            path: path2
                        });
                        
                        bestRoute.hops = 2;
                        bestRoute.splitRoutes = routeSplits;
                    }
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    function findComplexSplitCombinations(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint currentBest
    ) internal view returns (uint bestOutput, TradeRoute memory bestRoute) {
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestOutput = 0;
        
        // Try complex combinations with varying split percentages
        uint[] memory splitPercentages = new uint[](8);
        splitPercentages[0] = 5000; // 50%
        splitPercentages[1] = 3000; // 30%
        splitPercentages[2] = 2000; // 20%
        splitPercentages[3] = 1500; // 15%
        splitPercentages[4] = 1000; // 10%
        splitPercentages[5] = 750;  // 7.5%
        splitPercentages[6] = 500;  // 5%
        splitPercentages[7] = 250;  // 2.5%
        
        address[] memory intermediates = getPrimeIntermediateTokens(inputToken, outputToken);
        
        // Try different split combinations for 2-hop routes
        for (uint i = 0; i < intermediates.length && i < 3; i++) {
            address intermediate = intermediates[i];
            if (intermediate == address(0)) continue;
            
            // Find top routers for each hop
            (address[] memory firstHopRouters, uint[] memory firstHopOutputs) = findTopRoutersForPair(
                amountIn, inputToken, intermediate, MAX_SPLITS_PER_HOP
            );
            
            if (firstHopRouters[0] == address(0)) continue;
            
            // Test various split combinations
            for (uint s1 = 0; s1 < splitPercentages.length; s1++) {
                for (uint s2 = 0; s2 < splitPercentages.length; s2++) {
                    if (s1 >= firstHopRouters.length || s2 >= firstHopRouters.length) continue;
                    if (firstHopRouters[s1] == address(0) || firstHopRouters[s2] == address(0)) continue;
                    
                    uint totalFirstPercentage = splitPercentages[s1] + splitPercentages[s2];
                    if (totalFirstPercentage > 10000) continue;
                    
                    // Calculate first hop output with complex split
                    uint firstSplitAmount = (amountIn * splitPercentages[s1]) / 10000;
                    uint secondSplitAmount = (amountIn * splitPercentages[s2]) / 10000;
                    uint remainingAmount = amountIn - firstSplitAmount - secondSplitAmount;
                    
                    uint totalFirstHopOutput = 0;
                    
                    // First split
                    address[] memory path1 = getPath(inputToken, intermediate);
                    try IUniswapV2Router02(firstHopRouters[s1]).getAmountsOut(firstSplitAmount, path1) returns (uint[] memory res) {
                        totalFirstHopOutput += res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    // Second split
                    try IUniswapV2Router02(firstHopRouters[s2]).getAmountsOut(secondSplitAmount, path1) returns (uint[] memory res) {
                        totalFirstHopOutput += res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    // Remaining amount on best router
                    if (remainingAmount > 0) {
                        try IUniswapV2Router02(firstHopRouters[0]).getAmountsOut(remainingAmount, path1) returns (uint[] memory res) {
                            totalFirstHopOutput += res[res.length - 1];
                        } catch {
                            continue;
                        }
                    }
                    
                    if (totalFirstHopOutput == 0) continue;
                    
                    // Second hop with optimal split
                    (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
                        totalFirstHopOutput, intermediate, outputToken, new address[](0)
                    );
                    
                    if (secondHopOutput > bestOutput && secondHopOutput > currentBest) {
                        bestOutput = secondHopOutput;
                        bestRoute.hops = 2;
                        bestRoute.splitRoutes = new Split[][](2);
                        
                        // Construct complex first hop splits
                        uint splitCount = (remainingAmount > 0) ? 3 : 2;
                        bestRoute.splitRoutes[0] = new Split[](splitCount);
                        
                        bestRoute.splitRoutes[0][0] = Split({
                            router: firstHopRouters[s1],
                            percentage: splitPercentages[s1],
                            path: path1
                        });
                        
                        bestRoute.splitRoutes[0][1] = Split({
                            router: firstHopRouters[s2],
                            percentage: splitPercentages[s2],
                            path: path1
                        });
                        
                        if (remainingAmount > 0) {
                            bestRoute.splitRoutes[0][2] = Split({
                                router: firstHopRouters[0],
                                percentage: 10000 - totalFirstPercentage,
                                path: path1
                            });
                        }
                        
                        bestRoute.splitRoutes[1] = secondHopSplits;
                    }
                }
            }
        }
        
        return (bestOutput, bestRoute);
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
        // Create a more comprehensive list of potential intermediate tokens
        address[] memory commonTokens = getCommonIntermediates();
        address[] memory stablecoins = getCommonStablecoins();
        
        // Combine the two lists
        address[] memory allTokens = new address[](commonTokens.length + stablecoins.length);
        
        uint idx = 0;
        for (uint i = 0; i < commonTokens.length; i++) {
            allTokens[idx++] = commonTokens[i];
        }
        
        for (uint i = 0; i < stablecoins.length; i++) {
            // Avoid duplicates
            bool isDuplicate = false;
            for (uint j = 0; j < commonTokens.length; j++) {
                if (stablecoins[i] == commonTokens[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            
            if (!isDuplicate) {
                allTokens[idx++] = stablecoins[i];
            }
        }
        
        // Create a properly sized array with only the filled elements
        address[] memory result = new address[](idx);
        for (uint i = 0; i < idx; i++) {
            result[i] = allTokens[i];
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
    ) internal view returns (uint expectedOut, TradeRoute memory bestRoute) {
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


    function getCommonIntermediates() internal view returns (address[] memory) {
        // Common intermediates include WETH and top tokens on the network
        // The exact list will depend on the blockchain the contract is deployed to
        address[] memory intermediates = new address[](5);
        intermediates[0] = WETH;
        intermediates[1] = address(0xE0590015A873bF326bd645c3E1266d4db41C4E6B); // Major token 1
        intermediates[2] = address(0x0F0BDEbF0F83cD1EE3974779Bcb7315f9808c714); // Major token 2
        intermediates[3] = address(0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D); // Stablecoin 1
        intermediates[4] = address(0xf817257fed379853cDe0fa4F97AB987181B1E5Ea); // Stablecoin 2
        return intermediates;
    }

    function getCommonStablecoins() public pure returns (address[] memory) {
        address[] memory stablecoins = new address[](4);
        // Main stablecoins that typically have good liquidity
        stablecoins[0] = address(0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D); // Major stablecoin 1
        stablecoins[1] = address(0xf817257fed379853cDe0fa4F97AB987181B1E5Ea); // Major stablecoin 2
        stablecoins[2] = address(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI
        stablecoins[3] = address(0x0000000000085d4780B73119b644AE5ecd22b376); // TUSD
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
        
        // Try only the first stablecoin as intermediate to save gas
        address[] memory stablecoins = getCommonStablecoins();
        if (stablecoins.length > 0) {
            address stablecoin = stablecoins[0];
            if (stablecoin != address(0) && stablecoin != tokenIn && stablecoin != tokenOut) {
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

    function findBestTwoHopRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        address[] memory /* forbiddenTokens */
    ) public view returns (uint expectedOut, TradeRoute memory route) {
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(amountIn > 0, "Amount must be greater than 0");
        
        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = inputToken;
        bestRouteLocal.outputToken = outputToken;
        bestRouteLocal.hops = 2;
        bestRouteLocal.splitRoutes = new Split[][](2);

        uint bestOutputLocal = 0;
        Split[] memory bestFirstHopSplits;
        Split[] memory bestSecondHopSplits;
        
        // Get potential intermediate tokens - include whitelisted tokens + input/output + other potential tokens
        address[] memory whitelistedIntermediates = getAllWhitelistedTokens();
        
        // Count valid intermediates
        uint validCount = 0;
        for (uint i = 0; i < whitelistedIntermediates.length; i++) {
            if (whitelistedIntermediates[i] != address(0)) {
                validCount++;
            }
        }
        
        address[] memory potentialIntermediates = new address[](validCount + 2);
        
        // Add whitelisted tokens
        uint idx = 0;
        for (uint i = 0; i < whitelistedIntermediates.length && idx < validCount; i++) {
            if (whitelistedIntermediates[i] != address(0)) {
                potentialIntermediates[idx++] = whitelistedIntermediates[i];
            }
        }
        
        // Also add input and output tokens as potential intermediates
        potentialIntermediates[validCount] = inputToken;
        potentialIntermediates[validCount + 1] = outputToken;

        // Find common tokens that have high liquidity with both input and output
        potentialIntermediates = rankIntermediateTokens(inputToken, outputToken, potentialIntermediates);

        // Try all possible intermediates with priority to high-liquidity pairs
        for (uint i = 0; i < potentialIntermediates.length; i++) {
            address intermediate = potentialIntermediates[i];
            
            // Skip empty addresses
            if (intermediate == address(0)) continue;
            
            // Only use token if it's whitelisted or an input/output token
            if (!isWhitelisted(intermediate) && 
                intermediate != inputToken && 
                intermediate != outputToken) continue;
                
            // Standard case: use findBestSplitForHop for both hops with split percentages
            (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                intermediate,
                new address[](0)
            );

            if (firstHopOutput == 0 || firstHopSplits.length == 0) continue;
            
            (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHop(
                firstHopOutput,
                intermediate,
                outputToken,
                new address[](0)
            );

            if (secondHopOutput > bestOutputLocal && secondHopSplits.length > 0) {
                bestOutputLocal = secondHopOutput;
                bestFirstHopSplits = firstHopSplits;
                bestSecondHopSplits = secondHopSplits;
            }
            
            // Optimization: If best intermediate is found early, don't check all intermediates
            // This is a heuristic: use the highest ranked intermediates and if they work well, exit early
            if (i < 3 && bestOutputLocal > 0) {
                // Check if the next ranked token performs significantly better (>5% increase)
                bool shouldContinue = false;
                
                for (uint j = i + 1; j < potentialIntermediates.length && j <= i + 2; j++) {
                    address nextIntermediate = potentialIntermediates[j];
                    if (nextIntermediate == address(0)) continue;
                    
                    // Only use token if it's whitelisted or an input/output token
                    if (!isWhitelisted(nextIntermediate) && 
                        nextIntermediate != inputToken && 
                        nextIntermediate != outputToken) continue;
                    
                    (uint nextFirstHopOutput, ) = findBestSplitForHop(
                        amountIn,
                        inputToken,
                        nextIntermediate,
                        new address[](0)
                    );
                    
                    if (nextFirstHopOutput == 0) continue;
                    
                    (uint nextSecondHopOutput, ) = findBestSplitForHop(
                        nextFirstHopOutput,
                        nextIntermediate,
                        outputToken,
                        new address[](0)
                    );
                    
                    // If next token might give >5% better results, continue checking
                    if (nextSecondHopOutput > bestOutputLocal * 105 / 100) {
                        shouldContinue = true;
                        break;
                    }
                }
                
                if (!shouldContinue) {
                    break; // Early exit with current best route
                }
            }
            
            // Now try advanced routing: Multi-router with splits on the second hop
            // This handles more complex cases for better output
            uint firstHopOutputWithSplit = 0;
            
            // Try each router for first hop
            for (uint r1 = 0; r1 < routers.length; r1++) {
                address router1 = routers[r1];
                if (router1 == address(0)) continue;
                
                address[] memory path1 = getPath(inputToken, intermediate);
                if (path1.length < 2) continue;
                
                try IUniswapV2Router02(router1).getAmountsOut(amountIn, path1) returns (uint[] memory res) {
                    firstHopOutputWithSplit = res[res.length - 1];
                } catch {
                    continue;
                }
                
                if (firstHopOutputWithSplit == 0) continue;
                
                // Try dynamic split distribution for second hop
                address[] memory secondHopRouters = new address[](MAX_SPLITS_PER_HOP);
                uint[] memory secondHopOutputs = new uint[](MAX_SPLITS_PER_HOP);
                
                // Find the best routers for second hop
                (secondHopRouters, secondHopOutputs) = findTopRoutersForPair(
                    firstHopOutputWithSplit,
                    intermediate,
                    outputToken,
                    MAX_SPLITS_PER_HOP
                );
                
                if (secondHopRouters[0] == address(0)) continue;
                
                // Calculate optimal split percentages
                (uint splitOutput, uint[] memory splitPercentages) = optimizeSplitPercentages(
                    firstHopOutputWithSplit,
                    intermediate,
                    outputToken,
                    secondHopRouters
                );
                
                if (splitOutput > 0 && splitOutput > bestOutputLocal) {
                    bestOutputLocal = splitOutput;
                    
                    // Set up first hop
                    bestFirstHopSplits = new Split[](1);
                    bestFirstHopSplits[0] = Split({
                        router: router1,
                        percentage: 10000, // 100%
                        path: path1
                    });
                    
                    // Create optimized second hop splits
                    uint validSplitCount = 0;
                    for (uint s = 0; s < secondHopRouters.length; s++) {
                        if (secondHopRouters[s] != address(0) && splitPercentages[s] > 0) {
                            validSplitCount++;
                        }
                    }
                    
                    bestSecondHopSplits = new Split[](validSplitCount);
                    uint splitIndex = 0;
                    
                    for (uint s = 0; s < secondHopRouters.length; s++) {
                        if (secondHopRouters[s] != address(0) && splitPercentages[s] > 0) {
                            bestSecondHopSplits[splitIndex] = Split({
                                router: secondHopRouters[s],
                                percentage: splitPercentages[s],
                                path: getPath(intermediate, outputToken)
                            });
                            splitIndex++;
                        }
                    }
                }
                
                // Try special 3-token path (circular route)
                // This pattern can be very effective in some cases:
                // token A → token B → [split to: direct to C, and back to A then to C]
                if (firstHopOutputWithSplit > 0) {
                    for (uint r2 = 0; r2 < routers.length; r2++) {
                        address router2 = routers[r2];
                        if (router2 == address(0)) continue;
                        
                        address[] memory path2 = getPath(intermediate, outputToken);
                        if (path2.length < 2) continue;
                        
                        uint outputRouter2 = 0;
                        
                        // Try using 60% direct
                        uint directAmount = firstHopOutputWithSplit * 6 / 10;
                        try IUniswapV2Router02(router2).getAmountsOut(directAmount, path2) returns (uint[] memory res) {
                            outputRouter2 = res[res.length - 1];
                        } catch {
                            continue;
                        }
                        
                        if (outputRouter2 == 0) continue;
                        
                        // Try circular route with 40%
                        for (uint r3 = 0; r3 < routers.length; r3++) {
                            address router3 = routers[r3];
                            if (router3 == address(0)) continue;
                            
                            // Go back to input token
                            address[] memory pathToInput = getPath(intermediate, inputToken);
                            if (pathToInput.length < 2) continue;
                            
                            uint circularAmount = firstHopOutputWithSplit * 4 / 10;
                            uint intermediateToInput = 0;
                            
                            try IUniswapV2Router02(router3).getAmountsOut(circularAmount, pathToInput) returns (uint[] memory res) {
                                intermediateToInput = res[res.length - 1];
                            } catch {
                                continue;
                            }
                            
                            if (intermediateToInput == 0) continue;
                            
                            // Then to output
                            address[] memory pathToOutput = getPath(inputToken, outputToken);
                            if (pathToOutput.length < 2) continue;
                            
                            uint inputToOutput = 0;
                            
                            try IUniswapV2Router02(router3).getAmountsOut(intermediateToInput, pathToOutput) returns (uint[] memory res) {
                                inputToOutput = res[res.length - 1];
                            } catch {
                                continue;
                            }
                            
                            // Total output from both paths
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
                                    percentage: 6000, // 60%
                                    path: path2
                                });
                                bestSecondHopSplits[1] = Split({
                                    router: router3,
                                    percentage: 4000, // 40%
                                    path: pathToInput  // First part of complex path
                                });
                            }
                            
                            // Try other percentage splits for circular route
                            uint[] memory circularSplits = new uint[](5);
                            circularSplits[0] = 8000; // 80% direct, 20% circular
                            circularSplits[1] = 7000; // 70% direct, 30% circular
                            circularSplits[2] = 5000; // 50% direct, 50% circular
                            circularSplits[3] = 3000; // 30% direct, 70% circular
                            circularSplits[4] = 2000; // 20% direct, 80% circular
                            
                            for (uint s = 0; s < circularSplits.length; s++) {
                                uint directPct = circularSplits[s];
                                uint circularPct = 10000 - directPct;
                                
                                // Calculate direct output
                                uint directAmtTest = (firstHopOutputWithSplit * directPct) / 10000;
                                uint directOut = 0;
                                
                                try IUniswapV2Router02(router2).getAmountsOut(directAmtTest, path2) returns (uint[] memory res) {
                                    directOut = res[res.length - 1];
                                } catch {
                                    continue;
                                }
                                
                                // Calculate circular output
                                uint circularAmtTest = (firstHopOutputWithSplit * circularPct) / 10000;
                                uint backToInput = 0;
                                
                                try IUniswapV2Router02(router3).getAmountsOut(circularAmtTest, pathToInput) returns (uint[] memory res) {
                                    backToInput = res[res.length - 1];
                                } catch {
                                    continue;
                                }
                                
                                uint toOutput = 0;
                                try IUniswapV2Router02(router3).getAmountsOut(backToInput, pathToOutput) returns (uint[] memory res) {
                                    toOutput = res[res.length - 1];
                                } catch {
                                    continue;
                                }
                                
                                uint totalTestOutput = directOut + toOutput;
                                
                                if (totalTestOutput > bestOutputLocal) {
                                    bestOutputLocal = totalTestOutput;
                                    
                                    // Set up first hop
                                    bestFirstHopSplits = new Split[](1);
                                    bestFirstHopSplits[0] = Split({
                                        router: router1,
                                        percentage: 10000, // 100%
                                        path: path1
                                    });
                                    
                                    // Set up second hop with current split
                                    bestSecondHopSplits = new Split[](2);
                                    bestSecondHopSplits[0] = Split({
                                        router: router2,
                                        percentage: directPct,
                                        path: path2
                                    });
                                    bestSecondHopSplits[1] = Split({
                                        router: router3,
                                        percentage: circularPct,
                                        path: pathToInput
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }

        // Construct the final route
        if (bestOutputLocal > 0 && bestFirstHopSplits.length > 0 && bestSecondHopSplits.length > 0) {
            bestRouteLocal.splitRoutes[0] = bestFirstHopSplits;
            bestRouteLocal.splitRoutes[1] = bestSecondHopSplits;
            route = bestRouteLocal;
            expectedOut = bestOutputLocal;
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

        return (expectedOut, route);
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
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            topRouters = new address[](count);
            amountsOut = new uint[](count);
            return (topRouters, amountsOut);
        }
        
        require(count <= MAX_SPLITS_PER_HOP, "Count exceeds max splits");

        topRouters = new address[](count);
        amountsOut = new uint[](count);
        
        // Pre-filter valid routers for gas efficiency
        address[] memory validRouters = new address[](routers.length);
        uint[] memory validAmounts = new uint[](routers.length);
        uint validCount = 0;
        
        address[] memory path = getPath(tokenIn, tokenOut);
        if (path.length < 2) return (topRouters, amountsOut);

        // Single pass collection with early optimization
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;
            
            try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, path) returns (uint[] memory res) {
                if (res.length > 1 && res[res.length - 1] > 0) {
                    validRouters[validCount] = routers[i];
                    validAmounts[validCount] = res[res.length - 1];
                    validCount++;
                }
            } catch {
                // Skip invalid routers
            }
        }

        if (validCount == 0) return (topRouters, amountsOut);

        // Efficient partial sort - only sort what we need
        uint returnCount = validCount > count ? count : validCount;
        
        // Use selection sort for top N elements (more efficient for small N)
        for (uint i = 0; i < returnCount; i++) {
            uint maxIdx = i;
            for (uint j = i + 1; j < validCount; j++) {
                if (validAmounts[j] > validAmounts[maxIdx]) {
                    maxIdx = j;
                }
            }
            
            if (maxIdx != i) {
                // Swap
                uint tempAmount = validAmounts[i];
                validAmounts[i] = validAmounts[maxIdx];
                validAmounts[maxIdx] = tempAmount;
                
                address tempRouter = validRouters[i];
                validRouters[i] = validRouters[maxIdx];
                validRouters[maxIdx] = tempRouter;
            }
            
            topRouters[i] = validRouters[i];
            amountsOut[i] = validAmounts[i];
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
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (0, new uint[](0));
        }
        
        bestPercentages = new uint[](splitRouters.length);
        address[] memory path = getPath(tokenIn, tokenOut);
        if (path.length < 2) return (0, bestPercentages);
        
        // Enhanced data collection with price impact analysis
        uint[] memory baseOutputs = new uint[](splitRouters.length);
        uint[] memory efficiencyRatios = new uint[](splitRouters.length);
        uint[] memory priceImpacts = new uint[](splitRouters.length);
        uint[] memory liquidityDepths = new uint[](splitRouters.length);
        uint maxOutput = 0;
        uint bestSingleIdx = 0;
        uint validCount = 0;
        
        // Multi-dimensional analysis for optimal splitting
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] == address(0)) continue;
            
            // Base output calculation
            try IUniswapV2Router02(splitRouters[i]).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                if (amounts.length > 1) {
                    baseOutputs[i] = amounts[amounts.length - 1];
                    validCount++;
                    
                    if (baseOutputs[i] > maxOutput) {
                        maxOutput = baseOutputs[i];
                        bestSingleIdx = i;
                    }
                    
                    // Price impact analysis with multiple test amounts
                    uint smallTest = amountIn / 20;  // 5%
                    uint mediumTest = amountIn / 4;  // 25%
                    uint largeTest = (amountIn * 3) / 4; // 75%
                    
                    uint smallOutput = 0;
                    uint mediumOutput = 0;
                    uint largeOutput = 0;
                    
                    try IUniswapV2Router02(splitRouters[i]).getAmountsOut(smallTest, path) returns (uint[] memory res) {
                        smallOutput = res[res.length - 1];
                    } catch {}
                    
                    try IUniswapV2Router02(splitRouters[i]).getAmountsOut(mediumTest, path) returns (uint[] memory res) {
                        mediumOutput = res[res.length - 1];
                    } catch {}
                    
                    try IUniswapV2Router02(splitRouters[i]).getAmountsOut(largeTest, path) returns (uint[] memory res) {
                        largeOutput = res[res.length - 1];
                    } catch {}
                    
                    // Calculate price impact (higher = worse)
                    if (smallOutput > 0 && largeOutput > 0) {
                        uint expectedLargeOutput = (smallOutput * largeTest) / smallTest;
                        if (expectedLargeOutput > largeOutput) {
                            priceImpacts[i] = ((expectedLargeOutput - largeOutput) * 10000) / expectedLargeOutput;
                        }
                    }
                    
                    // Efficiency ratio with price impact adjustment
                    if (smallOutput > 0) {
                        uint rawEfficiency = (smallOutput * 10000) / smallTest;
                        // Adjust for price impact (lower impact = higher efficiency)
                        efficiencyRatios[i] = (rawEfficiency * (10000 - priceImpacts[i] / 2)) / 10000;
                    }
                    
                    // Liquidity depth estimation
                    liquidityDepths[i] = analyzeLiquidityDepth(tokenIn, tokenOut);
                }
            } catch {
                baseOutputs[i] = 0;
                efficiencyRatios[i] = 0;
                priceImpacts[i] = 10000; // Maximum impact for failed routers
            }
        }
        
        if (validCount == 0) return (0, bestPercentages);
        if (validCount == 1) {
            bestPercentages[bestSingleIdx] = 10000;
            return (maxOutput, bestPercentages);
        }
        
        // Advanced mathematical optimization using calculus-inspired approach
        uint[] memory currentAllocations = new uint[](splitRouters.length);
        uint totalAllocated = 0;
        uint iterations = 40; // More iterations for precision
        
        // Initialize with proportional allocation based on efficiency
        uint totalEfficiency = 0;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (efficiencyRatios[i] > 0) {
                totalEfficiency += efficiencyRatios[i];
            }
        }
        
        if (totalEfficiency > 0) {
            for (uint i = 0; i < splitRouters.length; i++) {
                if (efficiencyRatios[i] > 0) {
                    currentAllocations[i] = (efficiencyRatios[i] * 3000) / totalEfficiency; // Start with 30% allocation
                    totalAllocated += currentAllocations[i];
                }
            }
        }
        
        // Newton-Raphson inspired optimization
        for (uint iter = 0; iter < iterations && totalAllocated < 10000; iter++) {
            uint bestMarginalUtility = 0;
            uint bestRouterIdx = bestSingleIdx;
            uint allocationIncrement = (10000 - totalAllocated) / (iterations - iter + 1);
            if (allocationIncrement < 25) allocationIncrement = 25; // Minimum 0.25%
            if (allocationIncrement > 10000 - totalAllocated) allocationIncrement = 10000 - totalAllocated;
            
            // Calculate marginal utility for each router
            for (uint i = 0; i < splitRouters.length; i++) {
                if (baseOutputs[i] == 0) continue;
                
                uint newAllocation = currentAllocations[i] + allocationIncrement;
                if (newAllocation > 4000) continue; // Cap at 40% to encourage diversity
                
                // Sophisticated marginal utility calculation
                // Factors: efficiency, diminishing returns, price impact, liquidity depth
                uint currentUtil = currentAllocations[i];
                
                // Diminishing returns (quadratic decay)
                uint diminishingFactor = (currentUtil * currentUtil) / 20000;
                
                // Price impact penalty (exponential)
                uint priceImpactPenalty = (priceImpacts[i] * priceImpacts[i]) / 10000;
                
                // Liquidity bonus
                uint liquidityBonus = liquidityDepths[i] > 0 ? sqrt(liquidityDepths[i] / 1000) : 0;
                if (liquidityBonus > 1000) liquidityBonus = 1000; // Cap bonus
                
                // Combined marginal utility
                uint marginalUtility = (efficiencyRatios[i] * allocationIncrement * (10000 - diminishingFactor)) / 10000;
                marginalUtility = (marginalUtility * (10000 - priceImpactPenalty)) / 10000;
                marginalUtility = (marginalUtility * (10000 + liquidityBonus)) / 10000;
                
                if (marginalUtility > bestMarginalUtility) {
                    bestMarginalUtility = marginalUtility;
                    bestRouterIdx = i;
                }
            }
            
            // Allocate to best router
            if (totalAllocated + allocationIncrement <= 10000) {
                currentAllocations[bestRouterIdx] += allocationIncrement;
                totalAllocated += allocationIncrement;
            } else {
                currentAllocations[bestRouterIdx] += (10000 - totalAllocated);
                totalAllocated = 10000;
                break;
            }
        }
        
        // Ensure full allocation with smart remainder distribution
        if (totalAllocated < 10000) {
            uint remainder = 10000 - totalAllocated;
            
            // Distribute remainder to routers with lowest price impact
            uint minImpactIdx = bestSingleIdx;
            uint minImpact = priceImpacts[bestSingleIdx];
            
            for (uint i = 0; i < splitRouters.length; i++) {
                if (baseOutputs[i] > 0 && priceImpacts[i] < minImpact && currentAllocations[i] < 3000) {
                    minImpact = priceImpacts[i];
                    minImpactIdx = i;
                }
            }
            
            currentAllocations[minImpactIdx] += remainder;
        }
        
        // Precise output calculation using actual router calls
        bestOutput = calculateSplitOutput(amountIn, tokenIn, tokenOut, splitRouters, currentAllocations);
        
        // Validate improvement threshold - more aggressive threshold
        if (bestOutput <= maxOutput * 1002 / 1000) { // Less than 0.2% improvement
            for (uint i = 0; i < splitRouters.length; i++) {
                bestPercentages[i] = 0;
            }
            bestPercentages[bestSingleIdx] = 10000;
            bestOutput = maxOutput;
        } else {
            // Copy optimized allocations
            for (uint i = 0; i < splitRouters.length; i++) {
                bestPercentages[i] = currentAllocations[i];
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
