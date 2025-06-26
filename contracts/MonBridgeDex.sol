
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
    mapping(address => bool) public majorTokens;
    mapping(address => bool) public stablecoins;
    
    address[] public majorTokensList;
    address[] public stablecoinsList;

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
    event MajorTokenAdded(address token);
    event MajorTokenRemoved(address token);
    event StablecoinAdded(address token);
    event StablecoinRemoved(address token);
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

    function addMajorTokens(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Token cannot be zero address");
            if (!majorTokens[tokens[i]]) {
                majorTokens[tokens[i]] = true;
                majorTokensList.push(tokens[i]);
                // Also whitelist major tokens
                whitelistedTokens[tokens[i]] = true;
                emit MajorTokenAdded(tokens[i]);
                emit TokenWhitelisted(tokens[i]);
            }
        }
    }

    function removeMajorToken(address token) external onlyOwner {
        if (majorTokens[token]) {
            majorTokens[token] = false;
            // Remove from array
            for (uint i = 0; i < majorTokensList.length; i++) {
                if (majorTokensList[i] == token) {
                    majorTokensList[i] = majorTokensList[majorTokensList.length - 1];
                    majorTokensList.pop();
                    break;
                }
            }
            emit MajorTokenRemoved(token);
        }
    }

    function addStablecoins(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Token cannot be zero address");
            if (!stablecoins[tokens[i]]) {
                stablecoins[tokens[i]] = true;
                stablecoinsList.push(tokens[i]);
                // Also whitelist stablecoins
                whitelistedTokens[tokens[i]] = true;
                emit StablecoinAdded(tokens[i]);
                emit TokenWhitelisted(tokens[i]);
            }
        }
    }

    function removeStablecoin(address token) external onlyOwner {
        if (stablecoins[token]) {
            stablecoins[token] = false;
            // Remove from array
            for (uint i = 0; i < stablecoinsList.length; i++) {
                if (stablecoinsList[i] == token) {
                    stablecoinsList[i] = stablecoinsList[stablecoinsList.length - 1];
                    stablecoinsList.pop();
                    break;
                }
            }
            emit StablecoinRemoved(token);
        }
    }

    function getMajorTokens() external view returns (address[] memory) {
        return majorTokensList;
    }

    function getStablecoins() external view returns (address[] memory) {
        return stablecoinsList;
    }

    function isMajorToken(address token) public view returns (bool) {
        return majorTokens[token];
    }

    function isStablecoin(address token) public view returns (bool) {
        return stablecoins[token];
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
        
        // Use iterative deepening with gas budgeting
        uint gasCheckpoint = gasleft();
        uint maxGasPerStrategy = gasCheckpoint / 20; // Reserve gas for execution
        
        // Phase 1: Quick direct routes with advanced splitting (15% gas budget)
        if (gasleft() > maxGasPerStrategy) {
            try this.findBestDirectRouteComplex(
                amountIn,
                inputToken,
                outputToken
            ) returns (uint directOutput, TradeRoute memory directRoute) {
                if (directOutput > expectedOut) {
                    bestRoute = directRoute;
                    expectedOut = directOutput;
                }
            } catch {
                // Continue if direct route fails
            }
        }
        
        // Phase 2: Smart multi-hop with preference-based pruning (40% gas budget)
        if (gasleft() > maxGasPerStrategy * 2) {
            try this.findBestMultiHopWithPreferences(
                amountIn,
                inputToken,
                outputToken,
                expectedOut // Pass current best as threshold
            ) returns (uint multiHopOutput, TradeRoute memory multiHopRoute) {
                if (multiHopOutput > expectedOut) {
                    bestRoute = multiHopRoute;
                    expectedOut = multiHopOutput;
                }
            } catch {
                // Continue if multi-hop fails
            }
        }
        
        // Phase 3: Complex arbitrage and cross-router strategies (25% gas budget)
        if (gasleft() > maxGasPerStrategy) {
            try this.findBestComplexStrategies(
                amountIn,
                inputToken,
                outputToken,
                expectedOut
            ) returns (uint complexOutput, TradeRoute memory complexRoute) {
                if (complexOutput > expectedOut) {
                    bestRoute = complexRoute;
                    expectedOut = complexOutput;
                }
            } catch {
                // Continue if complex strategies fail
            }
        }
        
        // Phase 4: Deep exhaustive search if we still have gas (remaining gas budget)
        if (gasleft() > maxGasPerStrategy && expectedOut > 0) {
            try this.findBestDeepSearch(
                amountIn,
                inputToken,
                outputToken,
                expectedOut
            ) returns (uint deepOutput, TradeRoute memory deepRoute) {
                if (deepOutput > expectedOut) {
                    bestRoute = deepRoute;
                    expectedOut = deepOutput;
                }
            } catch {
                // Continue if deep search fails
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
    
    // Get prioritized tokens based on preference: WETH > Stablecoins > Major > Whitelisted
    function getPrioritizedIntermediateTokens(address inputToken, address outputToken) internal view returns (address[] memory) {
        // Calculate total size needed
        uint totalSize = 1; // WETH
        if (inputToken != WETH && outputToken != WETH) totalSize++;
        totalSize += stablecoinsList.length;
        totalSize += majorTokensList.length;
        totalSize += 20; // Limit other whitelisted to prevent gas issues
        
        address[] memory prioritized = new address[](totalSize);
        uint idx = 0;
        
        // Priority 1: WETH (if not input/output)
        if (inputToken != WETH && outputToken != WETH) {
            prioritized[idx++] = WETH;
        }
        
        // Priority 2: Stablecoins
        for (uint i = 0; i < stablecoinsList.length; i++) {
            if (stablecoinsList[i] != inputToken && stablecoinsList[i] != outputToken && stablecoinsList[i] != address(0)) {
                prioritized[idx++] = stablecoinsList[i];
            }
        }
        
        // Priority 3: Major tokens
        for (uint i = 0; i < majorTokensList.length; i++) {
            if (majorTokensList[i] != inputToken && majorTokensList[i] != outputToken && majorTokensList[i] != address(0)) {
                // Check if already added
                bool exists = false;
                for (uint j = 0; j < idx; j++) {
                    if (prioritized[j] == majorTokensList[i]) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    prioritized[idx++] = majorTokensList[i];
                }
            }
        }
        
        // Priority 4: Add input/output tokens for complex routes
        prioritized[idx++] = inputToken;
        prioritized[idx++] = outputToken;
        
        // Resize to actual count
        address[] memory result = new address[](idx);
        for (uint i = 0; i < idx; i++) {
            result[i] = prioritized[i];
        }
        
        return result;
    }
    
    // Phase 1: Advanced direct route finding
    function findBestDirectRouteComplex(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = 1;
        bestRoute.splitRoutes = new Split[][](1);
        uint bestOutput = 0;
        
        // Try advanced splitting with multiple paths per router
        (uint splitOutput, Split[] memory bestSplits) = findBestSplitForHopAdvanced(
            amountIn,
            inputToken,
            outputToken,
            new address[](0)
        );
        
        if (splitOutput > bestOutput) {
            bestOutput = splitOutput;
            bestRoute.splitRoutes[0] = bestSplits;
        }
        
        // Try single intermediate with each prioritized token
        address[] memory intermediates = getPrioritizedIntermediateTokens(inputToken, outputToken);
        
        for (uint i = 0; i < intermediates.length && i < 8 && gasleft() > 50000; i++) {
            address intermediate = intermediates[i];
            if (intermediate == address(0) || intermediate == inputToken || intermediate == outputToken) continue;
            
            // Try complex 2-hop with advanced splitting on both hops
            (uint complexOutput, TradeRoute memory complexRoute) = findBestTwoHopComplexRoute(
                amountIn,
                inputToken,
                intermediate,
                outputToken
            );
            
            if (complexOutput > bestOutput) {
                bestOutput = complexOutput;
                bestRoute = complexRoute;
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Enhanced 2-hop route with complex splitting on both hops
    function findBestTwoHopComplexRoute(
        uint amountIn,
        address inputToken,
        address intermediate,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = 2;
        bestRoute.splitRoutes = new Split[][](2);
        uint bestOutput = 0;
        
        // First hop: Find best splits from input to intermediate
        (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHopAdvanced(
            amountIn,
            inputToken,
            intermediate,
            new address[](0)
        );
        
        if (firstHopOutput == 0 || firstHopSplits.length == 0) return (0, bestRoute);
        
        // Second hop: Find best splits from intermediate to output
        (uint secondHopOutput, Split[] memory secondHopSplits) = findBestSplitForHopAdvanced(
            firstHopOutput,
            intermediate,
            outputToken,
            new address[](0)
        );
        
        if (secondHopOutput > 0 && secondHopSplits.length > 0) {
            bestRoute.splitRoutes[0] = firstHopSplits;
            bestRoute.splitRoutes[1] = secondHopSplits;
            bestOutput = secondHopOutput;
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Phase 2: Multi-hop with intelligent preferences
    function findBestMultiHopWithPreferences(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint currentBest
    ) external view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        uint bestOutput = currentBest;
        
        address[] memory prioritizedTokens = getPrioritizedIntermediateTokens(inputToken, outputToken);
        
        // Try 3-hop routes with preference-based selection
        for (uint hops = 3; hops <= MAX_HOPS && gasleft() > 100000; hops++) {
            bestRoute.hops = hops;
            bestRoute.splitRoutes = new Split[][](hops);
            
            // Use beam search with limited width to manage gas
            uint beamWidth = gasleft() > 200000 ? 5 : 3;
            
            (uint hopOutput, TradeRoute memory hopRoute) = findBestMultiHopBeamSearch(
                amountIn,
                inputToken,
                outputToken,
                hops,
                prioritizedTokens,
                beamWidth,
                bestOutput
            );
            
            if (hopOutput > bestOutput) {
                bestOutput = hopOutput;
                bestRoute = hopRoute;
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Beam search for multi-hop routes
    function findBestMultiHopBeamSearch(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hops,
        address[] memory prioritizedTokens,
        uint beamWidth,
        uint threshold
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (hops < 2) return (0, route);
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = hops;
        bestRoute.splitRoutes = new Split[][](hops);
        uint bestOutput = 0;
        
        // Limit intermediate token exploration based on gas
        uint maxIntermediates = gasleft() > 150000 ? 12 : 8;
        
        for (uint i = 0; i < prioritizedTokens.length && i < maxIntermediates && gasleft() > 60000; i++) {
            address firstIntermediate = prioritizedTokens[i];
            if (firstIntermediate == address(0) || firstIntermediate == inputToken || firstIntermediate == outputToken) continue;
            
            // First hop with advanced splitting
            (uint firstOutput, Split[] memory firstSplits) = findBestSplitForHopAdvanced(
                amountIn,
                inputToken,
                firstIntermediate,
                new address[](0)
            );
            
            if (firstOutput == 0 || firstSplits.length == 0) continue;
            
            if (hops == 2) {
                // Direct to output
                (uint finalOutput, Split[] memory finalSplits) = findBestSplitForHopAdvanced(
                    firstOutput,
                    firstIntermediate,
                    outputToken,
                    new address[](0)
                );
                
                if (finalOutput > bestOutput && finalOutput > threshold) {
                    bestOutput = finalOutput;
                    bestRoute.splitRoutes[0] = firstSplits;
                    bestRoute.splitRoutes[1] = finalSplits;
                }
            } else {
                // Continue with remaining hops
                address[] memory remainingPath = new address[](1);
                remainingPath[0] = firstIntermediate;
                
                (uint remainingOutput, TradeRoute memory remainingRoute) = findBestMultiHopBeamSearch(
                    firstOutput,
                    firstIntermediate,
                    outputToken,
                    hops - 1,
                    prioritizedTokens,
                    beamWidth - 1,
                    threshold
                );
                
                if (remainingOutput > bestOutput && remainingOutput > threshold) {
                    bestOutput = remainingOutput;
                    bestRoute.splitRoutes[0] = firstSplits;
                    for (uint j = 0; j < hops - 1 && j < remainingRoute.splitRoutes.length; j++) {
                        bestRoute.splitRoutes[j + 1] = remainingRoute.splitRoutes[j];
                    }
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Phase 3: Complex strategies
    function findBestComplexStrategies(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint currentBest
    ) external view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        uint bestOutput = currentBest;
        
        // Strategy 1: Arbitrage through high-liquidity pairs
        if (gasleft() > 80000) {
            (uint arbOutput, TradeRoute memory arbRoute) = findBestArbitrageRouteAdvanced(
                amountIn,
                inputToken,
                outputToken,
                currentBest
            );
            
            if (arbOutput > bestOutput) {
                bestOutput = arbOutput;
                bestRoute = arbRoute;
            }
        }
        
        // Strategy 2: Cross-router optimization
        if (gasleft() > 60000) {
            (uint crossOutput, TradeRoute memory crossRoute) = findBestCrossRouterRouteAdvanced(
                amountIn,
                inputToken,
                outputToken,
                currentBest
            );
            
            if (crossOutput > bestOutput) {
                bestOutput = crossOutput;
                bestRoute = crossRoute;
            }
        }
        
        // Strategy 3: Multi-path splitting across different strategies
        if (gasleft() > 40000) {
            (uint multiOutput, TradeRoute memory multiRoute) = findBestMultiPathStrategy(
                amountIn,
                inputToken,
                outputToken,
                currentBest
            );
            
            if (multiOutput > bestOutput) {
                bestOutput = multiOutput;
                bestRoute = multiRoute;
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Advanced arbitrage with preference-based selection
    function findBestArbitrageRouteAdvanced(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint threshold
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = 3;
        bestRoute.splitRoutes = new Split[][](3);
        uint bestOutput = 0;
        
        address[] memory prioritizedTokens = getPrioritizedIntermediateTokens(inputToken, outputToken);
        
        // Try triangular arbitrage with prioritized intermediates
        for (uint i = 0; i < prioritizedTokens.length && i < 6 && gasleft() > 30000; i++) {
            address intermediate = prioritizedTokens[i];
            if (intermediate == address(0) || intermediate == inputToken || intermediate == outputToken) continue;
            
            // Route: Input -> Intermediate -> Input -> Output
            (uint intermediateAmount, Split[] memory firstSplits) = findBestSplitForHopAdvanced(
                amountIn,
                inputToken,
                intermediate,
                new address[](0)
            );
            
            if (intermediateAmount == 0) continue;
            
            (uint backToInputAmount, Split[] memory secondSplits) = findBestSplitForHopAdvanced(
                intermediateAmount,
                intermediate,
                inputToken,
                new address[](0)
            );
            
            if (backToInputAmount == 0) continue;
            
            (uint finalAmount, Split[] memory thirdSplits) = findBestSplitForHopAdvanced(
                backToInputAmount,
                inputToken,
                outputToken,
                new address[](0)
            );
            
            if (finalAmount > bestOutput && finalAmount > threshold) {
                bestOutput = finalAmount;
                bestRoute.splitRoutes[0] = firstSplits;
                bestRoute.splitRoutes[1] = secondSplits;
                bestRoute.splitRoutes[2] = thirdSplits;
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Advanced cross-router optimization
    function findBestCrossRouterRouteAdvanced(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint threshold
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = 2;
        bestRoute.splitRoutes = new Split[][](2);
        uint bestOutput = 0;
        
        address[] memory prioritizedTokens = getPrioritizedIntermediateTokens(inputToken, outputToken);
        
        // Try cross-router strategies with prioritized intermediates
        for (uint i = 0; i < prioritizedTokens.length && i < 8 && gasleft() > 25000; i++) {
            address intermediate = prioritizedTokens[i];
            if (intermediate == address(0) || intermediate == inputToken || intermediate == outputToken) continue;
            
            // Try all router combinations
            for (uint r1 = 0; r1 < routers.length && gasleft() > 15000; r1++) {
                if (routers[r1] == address(0)) continue;
                
                address[] memory firstPath = getPath(inputToken, intermediate);
                uint firstOutput = 0;
                
                try IUniswapV2Router02(routers[r1]).getAmountsOut(amountIn, firstPath) returns (uint[] memory res) {
                    if (res.length > 1) firstOutput = res[res.length - 1];
                } catch { continue; }
                
                if (firstOutput == 0) continue;
                
                // Find best router for second hop
                (uint secondOutput, Split[] memory secondSplits) = findBestSplitForHopAdvanced(
                    firstOutput,
                    intermediate,
                    outputToken,
                    new address[](0)
                );
                
                if (secondOutput > bestOutput && secondOutput > threshold) {
                    bestOutput = secondOutput;
                    
                    bestRoute.splitRoutes[0] = new Split[](1);
                    bestRoute.splitRoutes[0][0] = Split({
                        router: routers[r1],
                        percentage: 10000,
                        path: firstPath
                    });
                    
                    bestRoute.splitRoutes[1] = secondSplits;
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Multi-path strategy combining different approaches
    function findBestMultiPathStrategy(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint threshold
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        // This function would implement complex multi-path strategies
        // For now, return the threshold to indicate no improvement
        return (threshold, route);
    }
    
    // Phase 4: Deep exhaustive search with intelligent pruning
    function findBestDeepSearch(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint currentBest
    ) external view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        uint bestOutput = currentBest;
        
        if (gasleft() < 50000) return (bestOutput, bestRoute);
        
        address[] memory prioritizedTokens = getPrioritizedIntermediateTokens(inputToken, outputToken);
        
        // Deep search with MAX_HOPS but intelligent pruning
        for (uint hops = 2; hops <= MAX_HOPS && gasleft() > 30000; hops++) {
            bestRoute.hops = hops;
            bestRoute.splitRoutes = new Split[][](hops);
            
            (uint deepOutput, TradeRoute memory deepRoute) = deepSearchWithPruning(
                amountIn,
                inputToken,
                outputToken,
                hops,
                prioritizedTokens,
                bestOutput
            );
            
            if (deepOutput > bestOutput) {
                bestOutput = deepOutput;
                bestRoute = deepRoute;
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Deep search with aggressive pruning to manage gas
    function deepSearchWithPruning(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hops,
        address[] memory prioritizedTokens,
        uint threshold
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (hops < 2 || gasleft() < 20000) return (0, route);
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = hops;
        bestRoute.splitRoutes = new Split[][](hops);
        uint bestOutput = 0;
        
        // Limit exploration based on remaining gas
        uint maxExploration = gasleft() > 40000 ? 6 : 3;
        
        for (uint i = 0; i < prioritizedTokens.length && i < maxExploration && gasleft() > 10000; i++) {
            address firstIntermediate = prioritizedTokens[i];
            if (firstIntermediate == address(0) || firstIntermediate == inputToken || firstIntermediate == outputToken) continue;
            
            // Quick profitability check before deep exploration
            uint estimatedOutput = quickEstimateOutput(amountIn, inputToken, firstIntermediate, outputToken, hops);
            if (estimatedOutput <= threshold) continue; // Prune unprofitable paths early
            
            (uint firstOutput, Split[] memory firstSplits) = findBestSplitForHopAdvanced(
                amountIn,
                inputToken,
                firstIntermediate,
                new address[](0)
            );
            
            if (firstOutput == 0) continue;
            
            if (hops == 2) {
                (uint finalOutput, Split[] memory finalSplits) = findBestSplitForHopAdvanced(
                    firstOutput,
                    firstIntermediate,
                    outputToken,
                    new address[](0)
                );
                
                if (finalOutput > bestOutput && finalOutput > threshold) {
                    bestOutput = finalOutput;
                    bestRoute.splitRoutes[0] = firstSplits;
                    bestRoute.splitRoutes[1] = finalSplits;
                }
            } else {
                (uint remainingOutput, TradeRoute memory remainingRoute) = deepSearchWithPruning(
                    firstOutput,
                    firstIntermediate,
                    outputToken,
                    hops - 1,
                    prioritizedTokens,
                    threshold
                );
                
                if (remainingOutput > bestOutput && remainingOutput > threshold) {
                    bestOutput = remainingOutput;
                    bestRoute.splitRoutes[0] = firstSplits;
                    for (uint j = 0; j < hops - 1 && j < remainingRoute.splitRoutes.length; j++) {
                        bestRoute.splitRoutes[j + 1] = remainingRoute.splitRoutes[j];
                    }
                }
            }
        }
        
        return (bestOutput, bestRoute);
    }
    
    // Quick estimate for path profitability to enable early pruning
    function quickEstimateOutput(
        uint amountIn,
        address inputToken,
        address intermediate,
        address outputToken,
        uint hops
    ) internal view returns (uint estimatedOutput) {
        // Simple estimation using best single router for each hop
        address bestRouter = routers[0];
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] != address(0)) {
                bestRouter = routers[i];
                break;
            }
        }
        
        if (bestRouter == address(0)) return 0;
        
        if (hops == 2) {
            address[] memory path1 = getPath(inputToken, intermediate);
            address[] memory path2 = getPath(intermediate, outputToken);
            
            try IUniswapV2Router02(bestRouter).getAmountsOut(amountIn, path1) returns (uint[] memory res1) {
                if (res1.length > 1) {
                    try IUniswapV2Router02(bestRouter).getAmountsOut(res1[res1.length - 1], path2) returns (uint[] memory res2) {
                        if (res2.length > 1) {
                            estimatedOutput = res2[res2.length - 1];
                        }
                    } catch { estimatedOutput = 0; }
                }
            } catch { estimatedOutput = 0; }
        } else {
            // For 3+ hops, use conservative estimate
            estimatedOutput = amountIn / (hops + 1); // Very conservative estimate
        }
        
        return estimatedOutput;
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
        // Calculate total size needed
        uint totalSize = 1 + majorTokensList.length + stablecoinsList.length; // +1 for WETH
        address[] memory intermediates = new address[](totalSize);
        
        uint index = 0;
        
        // Always include WETH as primary intermediate
        intermediates[index++] = WETH;
        
        // Add all major tokens
        for (uint i = 0; i < majorTokensList.length; i++) {
            intermediates[index++] = majorTokensList[i];
        }
        
        // Add all stablecoins
        for (uint i = 0; i < stablecoinsList.length; i++) {
            intermediates[index++] = stablecoinsList[i];
        }
        
        return intermediates;
    }

    function getCommonStablecoins() public view returns (address[] memory) {
        return stablecoinsList;
    }

    // Calculate price impact threshold based on amount and tokens
    function calculatePriceImpactThreshold(uint amountIn, address inputToken, address outputToken) internal view returns (uint threshold) {
        // Base threshold of 3%
        threshold = 300;
        
        // Adjust based on amount size
        if (amountIn > 10**21) { // Large trades
            threshold = 500; // 5%
        } else if (amountIn < 10**18) { // Small trades
            threshold = 150; // 1.5%
        }
        
        // Adjust based on token types
        if ((inputToken == WETH || outputToken == WETH) || 
            (isWhitelisted(inputToken) && isWhitelisted(outputToken))) {
            threshold = threshold * 7 / 10; // Reduce threshold for stable pairs
        }
        
        return threshold;
    }

    // Calculate price impact for a route with splits
    function calculateRoutesPriceImpact(uint amountIn, Split[] memory splits) internal view returns (uint totalImpact) {
        totalImpact = 0;
        uint totalWeight = 0;
        
        for (uint i = 0; i < splits.length; i++) {
            if (splits[i].router == address(0) || splits[i].percentage == 0) continue;
            
            uint splitAmount = (amountIn * splits[i].percentage) / 10000;
            if (splitAmount == 0) continue;
            
            // Calculate impact for this split
            uint impact = calculateSingleSplitPriceImpact(splitAmount, splits[i]);
            totalImpact += impact * splits[i].percentage;
            totalWeight += splits[i].percentage;
        }
        
        if (totalWeight > 0) {
            totalImpact = totalImpact / totalWeight;
        }
        
        return totalImpact;
    }

    // Calculate price impact for a single split
    function calculateSingleSplitPriceImpact(uint amountIn, Split memory split) internal view returns (uint impact) {
        if (split.path.length < 2) return 10000; // 100% impact for invalid paths
        
        // Test with small amount to estimate rate
        uint smallAmount = amountIn / 20; // 5% of amount
        if (smallAmount == 0) smallAmount = 1;
        
        uint smallOutput = 0;
        uint largeOutput = 0;
        
        try IUniswapV2Router02(split.router).getAmountsOut(smallAmount, split.path) returns (uint[] memory smallRes) {
            if (smallRes.length > 1) smallOutput = smallRes[smallRes.length - 1];
        } catch {
            return 10000; // 100% impact for failed routes
        }
        
        try IUniswapV2Router02(split.router).getAmountsOut(amountIn, split.path) returns (uint[] memory largeRes) {
            if (largeRes.length > 1) largeOutput = largeRes[largeRes.length - 1];
        } catch {
            return 10000; // 100% impact for failed routes
        }
        
        if (smallOutput == 0 || largeOutput == 0) return 10000;
        
        // Calculate expected large output based on small output rate
        uint expectedLargeOutput = (smallOutput * amountIn) / smallAmount;
        
        if (expectedLargeOutput > largeOutput) {
            impact = ((expectedLargeOutput - largeOutput) * 10000) / expectedLargeOutput;
        } else {
            impact = 0;
        }
        
        return impact;
    }

    // Enhanced split finding with advanced multi-path analysis
    function findBestSplitForHopAdvanced(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory forbiddenTokens
    ) public view returns (uint expectedOut, Split[] memory splits) {
        // Input validation
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (0, new Split[](0));
        }
        
        // Get all possible paths for this hop
        address[][] memory allPaths = findAllPossiblePaths(tokenIn, tokenOut, 1);
        
        // Evaluate each router with each path
        uint bestOutput = 0;
        Split[] memory bestSplits;
        
        // Try single router solutions first
        for (uint r = 0; r < routers.length; r++) {
            if (routers[r] == address(0)) continue;
            
            for (uint p = 0; p < allPaths.length; p++) {
                if (allPaths[p].length == 0) continue;
                
                uint output = 0;
                try IUniswapV2Router02(routers[r]).getAmountsOut(amountIn, allPaths[p]) returns (uint[] memory res) {
                    if (res.length > 1) output = res[res.length - 1];
                } catch {
                    continue;
                }
                
                if (output > bestOutput) {
                    bestOutput = output;
                    bestSplits = new Split[](1);
                    bestSplits[0] = Split({
                        router: routers[r],
                        percentage: 10000,
                        path: allPaths[p]
                    });
                }
            }
        }
        
        // Try multi-router splits with advanced optimization
        if (routers.length >= 2) {
            (uint multiRouterOutput, Split[] memory multiRouterSplits) = optimizeMultiRouterSplits(
                amountIn, tokenIn, tokenOut, allPaths
            );
            
            if (multiRouterOutput > bestOutput) {
                bestOutput = multiRouterOutput;
                bestSplits = multiRouterSplits;
            }
        }
        
        return (bestOutput, bestSplits);
    }

    // Find all possible paths between two tokens
    function findAllPossiblePaths(address tokenIn, address tokenOut, uint maxIntermediates) internal view returns (address[][] memory) {
        address[][] memory paths = new address[][](20); // Max 20 paths to limit gas
        uint pathCount = 0;
        
        // Direct path
        paths[pathCount] = new address[](2);
        paths[pathCount][0] = tokenIn;
        paths[pathCount][1] = tokenOut;
        pathCount++;
        
        if (maxIntermediates > 0 && pathCount < 20) {
            address[] memory intermediates = getAllWhitelistedTokens();
            
            // Single intermediate paths
            for (uint i = 0; i < intermediates.length && pathCount < 20; i++) {
                address intermediate = intermediates[i];
                if (intermediate == address(0) || intermediate == tokenIn || intermediate == tokenOut) continue;
                
                paths[pathCount] = new address[](3);
                paths[pathCount][0] = tokenIn;
                paths[pathCount][1] = intermediate;
                paths[pathCount][2] = tokenOut;
                pathCount++;
            }
        }
        
        // Resize array to actual count
        address[][] memory result = new address[][](pathCount);
        for (uint i = 0; i < pathCount; i++) {
            result[i] = paths[i];
        }
        
        return result;
    }

    // Optimize multi-router splits with advanced algorithms
    function optimizeMultiRouterSplits(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[][] memory paths
    ) internal view returns (uint bestOutput, Split[] memory bestSplits) {
        bestOutput = 0;
        
        // Get top performing router-path combinations
        uint maxCombinations = routers.length * paths.length;
        if (maxCombinations > 20) maxCombinations = 20; // Limit to prevent gas issues
        
        address[] memory routersList = new address[](maxCombinations);
        address[][] memory pathsList = new address[][](maxCombinations);
        uint[] memory outputsList = new uint[](maxCombinations);
        uint combinationCount = 0;
        
        // Evaluate all router-path combinations
        for (uint r = 0; r < routers.length && combinationCount < maxCombinations; r++) {
            if (routers[r] == address(0)) continue;
            
            for (uint p = 0; p < paths.length && combinationCount < maxCombinations; p++) {
                if (paths[p].length == 0) continue;
                
                uint output = 0;
                try IUniswapV2Router02(routers[r]).getAmountsOut(amountIn, paths[p]) returns (uint[] memory res) {
                    if (res.length > 1) output = res[res.length - 1];
                } catch {
                    continue;
                }
                
                if (output > 0) {
                    routersList[combinationCount] = routers[r];
                    pathsList[combinationCount] = paths[p];
                    outputsList[combinationCount] = output;
                    combinationCount++;
                }
            }
        }
        
        if (combinationCount == 0) return (0, new Split[](0));
        
        // Sort combinations by output (simple bubble sort for small arrays)
        for (uint i = 0; i < combinationCount; i++) {
            for (uint j = i + 1; j < combinationCount; j++) {
                if (outputsList[j] > outputsList[i]) {
                    // Swap outputs
                    uint tempOutput = outputsList[i];
                    outputsList[i] = outputsList[j];
                    outputsList[j] = tempOutput;
                    
                    // Swap routers
                    address tempRouter = routersList[i];
                    routersList[i] = routersList[j];
                    routersList[j] = tempRouter;
                    
                    // Swap paths
                    address[] memory tempPath = pathsList[i];
                    pathsList[i] = pathsList[j];
                    pathsList[j] = tempPath;
                }
            }
        }
        
        // Try different split combinations
        uint maxSplits = combinationCount > MAX_SPLITS_PER_HOP ? MAX_SPLITS_PER_HOP : combinationCount;
        
        for (uint splitCount = 1; splitCount <= maxSplits; splitCount++) {
            (uint output, uint[] memory percentages) = optimizeSplitPercentagesAdvanced(
                amountIn, tokenIn, tokenOut, routersList, pathsList, splitCount
            );
            
            if (output > bestOutput) {
                bestOutput = output;
                
                // Create splits array
                uint validSplits = 0;
                for (uint i = 0; i < splitCount; i++) {
                    if (percentages[i] > 0) validSplits++;
                }
                
                bestSplits = new Split[](validSplits);
                uint splitIndex = 0;
                
                for (uint i = 0; i < splitCount; i++) {
                    if (percentages[i] > 0) {
                        bestSplits[splitIndex] = Split({
                            router: routersList[i],
                            percentage: percentages[i],
                            path: pathsList[i]
                        });
                        splitIndex++;
                    }
                }
            }
        }
        
        return (bestOutput, bestSplits);
    }

    // Advanced split percentage optimization
    function optimizeSplitPercentagesAdvanced(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory routersList,
        address[][] memory pathsList,
        uint splitCount
    ) internal view returns (uint bestOutput, uint[] memory bestPercentages) {
        bestOutput = 0;
        bestPercentages = new uint[](splitCount);
        
        // Calculate price impacts for each router-path combination
        uint[] memory priceImpacts = new uint[](splitCount);
        uint[] memory baseOutputs = new uint[](splitCount);
        
        for (uint i = 0; i < splitCount; i++) {
            if (routersList[i] == address(0) || pathsList[i].length == 0) continue;
            
            // Calculate price impact
            uint smallAmount = amountIn / 20; // 5% test
            if (smallAmount == 0) smallAmount = 1;
            
            uint smallOut = 0;
            uint largeOut = 0;
            
            try IUniswapV2Router02(routersList[i]).getAmountsOut(smallAmount, pathsList[i]) returns (uint[] memory res) {
                if (res.length > 1) smallOut = res[res.length - 1];
            } catch {
                priceImpacts[i] = 10000; // 100% impact
                continue;
            }
            
            try IUniswapV2Router02(routersList[i]).getAmountsOut(amountIn, pathsList[i]) returns (uint[] memory res) {
                if (res.length > 1) {
                    largeOut = res[res.length - 1];
                    baseOutputs[i] = largeOut;
                }
            } catch {
                priceImpacts[i] = 10000; // 100% impact
                continue;
            }
            
            if (smallOut > 0 && largeOut > 0) {
                uint expectedLarge = (smallOut * amountIn) / smallAmount;
                if (expectedLarge > largeOut) {
                    priceImpacts[i] = ((expectedLarge - largeOut) * 10000) / expectedLarge;
                } else {
                    priceImpacts[i] = 0;
                }
            } else {
                priceImpacts[i] = 10000;
            }
        }
        
        // Generate optimal distribution based on price impacts and outputs
        uint totalInvertedImpact = 0;
        uint[] memory invertedImpacts = new uint[](splitCount);
        
        for (uint i = 0; i < splitCount; i++) {
            if (baseOutputs[i] > 0) {
                uint impact = priceImpacts[i] > 5000 ? 5000 : priceImpacts[i]; // Cap at 50%
                invertedImpacts[i] = 5000 - impact;
                totalInvertedImpact += invertedImpacts[i];
            }
        }
        
        if (totalInvertedImpact > 0) {
            // Distribute based on inverted price impact
            for (uint i = 0; i < splitCount; i++) {
                if (baseOutputs[i] > 0) {
                    bestPercentages[i] = (invertedImpacts[i] * 10000) / totalInvertedImpact;
                }
            }
            
            // Calculate output with these percentages
            bestOutput = calculateSplitOutputAdvanced(amountIn, routersList, pathsList, bestPercentages, splitCount);
        }
        
        // Try additional distribution strategies
        uint[][] memory testDistributions = generateAdvancedTestDistributions(splitCount, baseOutputs, priceImpacts);
        
        for (uint d = 0; d < testDistributions.length; d++) {
            uint output = calculateSplitOutputAdvanced(amountIn, routersList, pathsList, testDistributions[d], splitCount);
            if (output > bestOutput) {
                bestOutput = output;
                bestPercentages = testDistributions[d];
            }
        }
        
        return (bestOutput, bestPercentages);
    }

    // Calculate split output for advanced routing
    function calculateSplitOutputAdvanced(
        uint amountIn,
        address[] memory routersList,
        address[][] memory pathsList,
        uint[] memory percentages,
        uint splitCount
    ) internal view returns (uint totalOutput) {
        totalOutput = 0;
        
        for (uint i = 0; i < splitCount; i++) {
            if (routersList[i] == address(0) || pathsList[i].length == 0 || percentages[i] == 0) continue;
            
            uint splitAmount = (amountIn * percentages[i]) / 10000;
            if (splitAmount == 0) continue;
            
            try IUniswapV2Router02(routersList[i]).getAmountsOut(splitAmount, pathsList[i]) returns (uint[] memory res) {
                if (res.length > 1) {
                    totalOutput += res[res.length - 1];
                }
            } catch {
                // Skip failed routes
            }
        }
        
        return totalOutput;
    }

    // Generate advanced test distributions
    function generateAdvancedTestDistributions(
        uint splitCount,
        uint[] memory baseOutputs,
        uint[] memory priceImpacts
    ) internal pure returns (uint[][] memory) {
        uint[][] memory distributions = new uint[][](15); // More focused distributions
        
        // 100% to best route
        distributions[0] = new uint[](splitCount);
        uint bestIndex = 0;
        uint bestOutput = 0;
        for (uint i = 0; i < splitCount; i++) {
            if (baseOutputs[i] > bestOutput) {
                bestOutput = baseOutputs[i];
                bestIndex = i;
            }
        }
        distributions[0][bestIndex] = 10000;
        
        if (splitCount >= 2) {
            // Find second best
            uint secondBestIndex = 0;
            uint secondBestOutput = 0;
            for (uint i = 0; i < splitCount; i++) {
                if (i != bestIndex && baseOutputs[i] > secondBestOutput) {
                    secondBestOutput = baseOutputs[i];
                    secondBestIndex = i;
                }
            }
            
            // Various two-way splits
            uint[] memory ratios = new uint[](8);
            ratios[0] = 9000; ratios[1] = 8000; ratios[2] = 7000; ratios[3] = 6000;
            ratios[4] = 5500; ratios[5] = 5000; ratios[6] = 4000; ratios[7] = 3000;
            
            for (uint r = 0; r < 8; r++) {
                distributions[r + 1] = new uint[](splitCount);
                distributions[r + 1][bestIndex] = ratios[r];
                distributions[r + 1][secondBestIndex] = 10000 - ratios[r];
            }
            
            // Equal distribution among top performers
            distributions[9] = new uint[](splitCount);
            uint validRoutes = 0;
            for (uint i = 0; i < splitCount; i++) {
                if (baseOutputs[i] > 0) validRoutes++;
            }
            
            if (validRoutes > 0) {
                uint equalShare = 10000 / validRoutes;
                for (uint i = 0; i < splitCount; i++) {
                    if (baseOutputs[i] > 0) {
                        distributions[9][i] = equalShare;
                    }
                }
            }
            
            // Impact-based distribution (favor low impact routes)
            distributions[10] = new uint[](splitCount);
            uint totalWeight = 0;
            for (uint i = 0; i < splitCount; i++) {
                if (baseOutputs[i] > 0) {
                    uint weight = priceImpacts[i] < 1000 ? 1000 - priceImpacts[i] : 1;
                    distributions[10][i] = weight;
                    totalWeight += weight;
                }
            }
            
            if (totalWeight > 0) {
                for (uint i = 0; i < splitCount; i++) {
                    if (distributions[10][i] > 0) {
                        distributions[10][i] = (distributions[10][i] * 10000) / totalWeight;
                    }
                }
            }
            
            // Output-weighted distribution
            distributions[11] = new uint[](splitCount);
            uint totalOutputWeight = 0;
            for (uint i = 0; i < splitCount; i++) {
                totalOutputWeight += baseOutputs[i];
            }
            
            if (totalOutputWeight > 0) {
                for (uint i = 0; i < splitCount; i++) {
                    distributions[11][i] = (baseOutputs[i] * 10000) / totalOutputWeight;
                }
            }
            
            // Hybrid distribution (output + low impact)
            distributions[12] = new uint[](splitCount);
            for (uint i = 0; i < splitCount; i++) {
                if (baseOutputs[i] > 0) {
                    uint outputWeight = baseOutputs[i];
                    uint impactWeight = priceImpacts[i] < 2000 ? 2000 - priceImpacts[i] : 1;
                    distributions[12][i] = sqrt(outputWeight * impactWeight);
                }
            }
            
            uint hybridTotal = 0;
            for (uint i = 0; i < splitCount; i++) {
                hybridTotal += distributions[12][i];
            }
            
            if (hybridTotal > 0) {
                for (uint i = 0; i < splitCount; i++) {
                    distributions[12][i] = (distributions[12][i] * 10000) / hybridTotal;
                }
            }
            
            // Conservative split (80-20 best two)
            distributions[13] = new uint[](splitCount);
            distributions[13][bestIndex] = 8000;
            distributions[13][secondBestIndex] = 2000;
            
            // Aggressive exploration (60-25-15 top three)
            if (splitCount >= 3) {
                uint thirdBestIndex = 0;
                uint thirdBestOutput = 0;
                for (uint i = 0; i < splitCount; i++) {
                    if (i != bestIndex && i != secondBestIndex && baseOutputs[i] > thirdBestOutput) {
                        thirdBestOutput = baseOutputs[i];
                        thirdBestIndex = i;
                    }
                }
                
                distributions[14] = new uint[](splitCount);
                distributions[14][bestIndex] = 6000;
                distributions[14][secondBestIndex] = 2500;
                distributions[14][thirdBestIndex] = 1500;
            }
        }
        
        return distributions;
    }

    // Enhanced multi-hop route finding
    function findBestMultiHopRouteAdvanced(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hops,
        address[] memory forbiddenTokens
    ) internal view returns (uint expectedOut, TradeRoute memory bestRoute) {
        require(hops >= 2 && hops <= MAX_HOPS, "Invalid hop count");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(amountIn > 0, "Amount must be greater than 0");

        TradeRoute memory bestRouteLocal;
        bestRouteLocal.inputToken = inputToken;
        bestRouteLocal.outputToken = outputToken;
        bestRouteLocal.hops = hops;
        bestRouteLocal.splitRoutes = new Split[][](hops);
        uint bestOutputLocal = 0;

        // Get expanded list of intermediate tokens
        address[] memory intermediates = getExpandedIntermediateTokens(inputToken, outputToken);
        
        // For each possible first hop token
        for (uint i = 0; i < intermediates.length; i++) {
            address firstHopToken = intermediates[i];
            if (!isValidTokenForPath(firstHopToken, inputToken, outputToken)) continue;

            // Get best splits for first hop using advanced method
            uint firstHopOutput;
            Split[] memory firstHopSplits;
            (firstHopOutput, firstHopSplits) = findBestSplitForHopAdvanced(
                amountIn,
                inputToken,
                firstHopToken,
                forbiddenTokens
            );
            
            if (firstHopOutput == 0 || firstHopSplits.length == 0) continue;
            
            if (hops == 2) {
                // For 2-hop routes, find best second hop
                uint secondHopOutput;
                Split[] memory secondHopSplits;
                (secondHopOutput, secondHopSplits) = findBestSplitForHopAdvanced(
                    firstHopOutput,
                    firstHopToken,
                    outputToken,
                    forbiddenTokens
                );
                
                if (secondHopOutput > bestOutputLocal && secondHopSplits.length > 0) {
                    bestOutputLocal = secondHopOutput;
                    bestRouteLocal.splitRoutes[0] = firstHopSplits;
                    bestRouteLocal.splitRoutes[1] = secondHopSplits;
                }
            } else {
                // For 3+ hop routes, recurse
                address[] memory newForbiddenTokens = new address[](forbiddenTokens.length + 1);
                for (uint j = 0; j < forbiddenTokens.length; j++) {
                    newForbiddenTokens[j] = forbiddenTokens[j];
                }
                newForbiddenTokens[forbiddenTokens.length] = firstHopToken;
                
                uint remainingOutput;
                TradeRoute memory remainingRoute;
                (remainingOutput, remainingRoute) = findBestMultiHopRouteAdvanced(
                    firstHopOutput,
                    firstHopToken,
                    outputToken,
                    hops - 1,
                    newForbiddenTokens
                );
                
                if (remainingOutput > bestOutputLocal && remainingRoute.hops > 0) {
                    bestOutputLocal = remainingOutput;
                    bestRouteLocal.splitRoutes[0] = firstHopSplits;
                    for (uint k = 0; k < hops - 1 && k < remainingRoute.splitRoutes.length; k++) {
                        bestRouteLocal.splitRoutes[k + 1] = remainingRoute.splitRoutes[k];
                    }
                }
            }
        }

        return (bestOutputLocal, bestRouteLocal);
    }

    // Get expanded list of intermediate tokens with better coverage
    function getExpandedIntermediateTokens(address inputToken, address outputToken) internal view returns (address[] memory) {
        address[] memory common = getCommonIntermediates();
        address[] memory stablecoins = getCommonStablecoins();
        address[] memory whitelisted = getAllWhitelistedTokens();
        
        // Combine all lists with deduplication
        address[] memory expanded = new address[](common.length + stablecoins.length + whitelisted.length + 2);
        uint idx = 0;
        
        // Add common intermediates
        for (uint i = 0; i < common.length; i++) {
            if (common[i] != address(0)) {
                expanded[idx++] = common[i];
            }
        }
        
        // Add stablecoins (with dedup check)
        for (uint i = 0; i < stablecoins.length; i++) {
            if (stablecoins[i] == address(0)) continue;
            bool isDuplicate = false;
            for (uint j = 0; j < idx; j++) {
                if (expanded[j] == stablecoins[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                expanded[idx++] = stablecoins[i];
            }
        }
        
        // Add whitelisted tokens (with dedup check)
        for (uint i = 0; i < whitelisted.length; i++) {
            if (whitelisted[i] == address(0)) continue;
            bool isDuplicate = false;
            for (uint j = 0; j < idx; j++) {
                if (expanded[j] == whitelisted[i]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                expanded[idx++] = whitelisted[i];
            }
        }
        
        // Add input and output tokens as potential intermediates
        expanded[idx++] = inputToken;
        expanded[idx++] = outputToken;
        
        // Create properly sized result array
        address[] memory result = new address[](idx);
        for (uint i = 0; i < idx; i++) {
            result[i] = expanded[i];
        }
        
        return result;
    }

    // Find arbitrage opportunities (circular routes)
    function findBestArbitrageRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        // Try triangular arbitrage: Input -> Intermediate -> Input -> Output
        address[] memory intermediates = getExpandedIntermediateTokens(inputToken, outputToken);
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = 3;
        bestRoute.splitRoutes = new Split[][](3);
        uint bestOutput = 0;
        
        for (uint i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == inputToken || intermediate == outputToken || intermediate == address(0)) continue;
            
            // Route: Input -> Intermediate -> Input -> Output
            uint intermediateAmount;
            Split[] memory firstSplits;
            (intermediateAmount, firstSplits) = findBestSplitForHopAdvanced(
                amountIn,
                inputToken,
                intermediate,
                new address[](0)
            );
            
            if (intermediateAmount == 0 || firstSplits.length == 0) continue;
            
            uint backToInputAmount;
            Split[] memory secondSplits;
            (backToInputAmount, secondSplits) = findBestSplitForHopAdvanced(
                intermediateAmount,
                intermediate,
                inputToken,
                new address[](0)
            );
            
            if (backToInputAmount == 0 || secondSplits.length == 0) continue;
            
            uint finalAmount;
            Split[] memory thirdSplits;
            (finalAmount, thirdSplits) = findBestSplitForHopAdvanced(
                backToInputAmount,
                inputToken,
                outputToken,
                new address[](0)
            );
            
            if (finalAmount > bestOutput && thirdSplits.length > 0) {
                bestOutput = finalAmount;
                bestRoute.splitRoutes[0] = firstSplits;
                bestRoute.splitRoutes[1] = secondSplits;
                bestRoute.splitRoutes[2] = thirdSplits;
            }
        }
        
        return (bestOutput, bestRoute);
    }

    // Find best cross-router opportunities
    function findBestCrossRouterRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        // Try routes that use different routers for different hops to exploit price differences
        address[] memory intermediates = getExpandedIntermediateTokens(inputToken, outputToken);
        
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = 2;
        bestRoute.splitRoutes = new Split[][](2);
        uint bestOutput = 0;
        
        for (uint i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == inputToken || intermediate == outputToken || intermediate == address(0)) continue;
            
            // Try all router combinations for two hops
            for (uint r1 = 0; r1 < routers.length; r1++) {
                if (routers[r1] == address(0)) continue;
                
                for (uint r2 = 0; r2 < routers.length; r2++) {
                    if (routers[r2] == address(0)) continue;
                    
                    // First hop
                    address[] memory firstPath = getPath(inputToken, intermediate);
                    uint firstOutput = 0;
                    
                    try IUniswapV2Router02(routers[r1]).getAmountsOut(amountIn, firstPath) returns (uint[] memory res) {
                        if (res.length > 1) firstOutput = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    if (firstOutput == 0) continue;
                    
                    // Second hop
                    address[] memory secondPath = getPath(intermediate, outputToken);
                    uint secondOutput = 0;
                    
                    try IUniswapV2Router02(routers[r2]).getAmountsOut(firstOutput, secondPath) returns (uint[] memory res) {
                        if (res.length > 1) secondOutput = res[res.length - 1];
                    } catch {
                        continue;
                    }
                    
                    if (secondOutput > bestOutput) {
                        bestOutput = secondOutput;
                        
                        bestRoute.splitRoutes[0] = new Split[](1);
                        bestRoute.splitRoutes[0][0] = Split({
                            router: routers[r1],
                            percentage: 10000,
                            path: firstPath
                        });
                        
                        bestRoute.splitRoutes[1] = new Split[](1);
                        bestRoute.splitRoutes[1][0] = Split({
                            router: routers[r2],
                            percentage: 10000,
                            path: secondPath
                        });
                    }
                }
            }
        }
        
        return (bestOutput, bestRoute);
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
    
    // Helper method to rank intermediate tokens by liquidity with preference for major tokens and stablecoins
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
        
        // Calculate enhanced liquidity scores with preference multipliers
        uint[] memory liquidityScores = new uint[](intermediates.length);
        
        for (uint i = 0; i < intermediates.length; i++) {
            if (rankedTokens[i] == address(0)) continue;
            
            // Analyze liquidity on both sides
            uint liquidityWithInput = analyzeLiquidityDepth(inputToken, rankedTokens[i]);
            uint liquidityWithOutput = analyzeLiquidityDepth(rankedTokens[i], outputToken);
            
            // Base score is the geometric mean of liquidity on both sides
            uint baseScore = 0;
            if (liquidityWithInput > 0 && liquidityWithOutput > 0) {
                baseScore = sqrt(liquidityWithInput * liquidityWithOutput);
            }
            
            // Apply preference multipliers without excessive bias
            uint preferenceMultiplier = 100; // Base 100%
            
            // WETH gets highest preference
            if (rankedTokens[i] == WETH) {
                preferenceMultiplier = 120; // 20% bonus
            }
            // Stablecoins get slight preference 
            else if (isStablecoin(rankedTokens[i])) {
                preferenceMultiplier = 110; // 10% bonus
            }
            // Major tokens get slight preference
            else if (isMajorToken(rankedTokens[i])) {
                preferenceMultiplier = 105; // 5% bonus
            }
            
            // Apply the multiplier (divide by 100 to maintain scale)
            liquidityScores[i] = (baseScore * preferenceMultiplier) / 100;
        }
        
        // Sort tokens by enhanced score (bubble sort for simplicity)
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
