
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
        
        // Initialize empty arrays for intermediates and stablecoins
        // Owner will populate these after deployment
        commonIntermediates = new address[](0);
        commonStablecoins = new address[](0);
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

    // Helper struct to track router usage in multi-hop paths
    struct RouterUsage {
        address router;
        uint usageCount;
    }
    
    // Helper function to check if a router has been used up to maximum allowed times
    function canUseRouter(address router, RouterUsage[] memory usages, uint maxUsagePerRouter) internal pure returns (bool) {
        if (maxUsagePerRouter == 0) return false;
        
        for (uint i = 0; i < usages.length; i++) {
            if (usages[i].router == router) {
                return usages[i].usageCount < maxUsagePerRouter;
            }
        }
        
        // Router not found in usage array, can use it
        return true;
    }
    
    // Helper function to update router usage
    function updateRouterUsage(address router, RouterUsage[] memory usages) internal pure {
        for (uint i = 0; i < usages.length; i++) {
            if (usages[i].router == router) {
                usages[i].usageCount++;
                return;
            }
        }
        
        // If router not found and there's space, add it
        for (uint i = 0; i < usages.length; i++) {
            if (usages[i].router == address(0)) {
                usages[i].router = router;
                usages[i].usageCount = 1;
                return;
            }
        }
    }
    
    // Helper function to get expanded trade path using multiple hops within a single router
    function getExpandedPath(
        address inputToken,
        address outputToken,
        address router,
        uint maxHopsPerRouter
    ) internal view returns (address[] memory path, uint expectedOutput, uint hops) {
        // Try direct path first
        address[] memory directPath = new address[](2);
        directPath[0] = inputToken;
        directPath[1] = outputToken;
        
        try IUniswapV2Router02(router).getAmountsOut(1, directPath) returns (uint[] memory amounts) {
            if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                return (directPath, amounts[amounts.length - 1], 1);
            }
        } catch {
            // Continue to try multi-hop paths
        }
        
        // Get all possible intermediate tokens and prioritize by relevance
        address[] memory allIntermediates = getAllWhitelistedTokens();
        
        // Rank intermediates by liquidity - prioritize tokens with strong pairs
        address[] memory intermediates = rankIntermediateTokens(inputToken, outputToken, allIntermediates);
        
        // Try specialized high-liquidity intermediates first
        address[] memory specialIntermediates = new address[](3);
        specialIntermediates[0] = WETH; // Always try WETH first
        
        // Try to include top stablecoins
        address[] memory stablecoins = getCommonStablecoins();
        if (stablecoins.length > 0) {
            specialIntermediates[1] = stablecoins[0];
        }
        if (stablecoins.length > 1) {
            specialIntermediates[2] = stablecoins[1];
        }
        
        // First try special intermediates for 2-hop path (usually most efficient)
        for (uint i = 0; i < specialIntermediates.length; i++) {
            address intermediate = specialIntermediates[i];
            if (intermediate == address(0) || 
                intermediate == inputToken || 
                intermediate == outputToken) {
                continue;
            }
            
            address[] memory hopPath = new address[](3);
            hopPath[0] = inputToken;
            hopPath[1] = intermediate;
            hopPath[2] = outputToken;
            
            try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                if (amounts.length > 2 && amounts[amounts.length - 1] > 0) {
                    if (amounts[amounts.length - 1] > expectedOutput) {
                        path = hopPath;
                        expectedOutput = amounts[amounts.length - 1];
                        hops = 2;
                    }
                }
            } catch {
                // Try next intermediate
            }
        }
        
        // Try 2-hop path (3 tokens total) with ranked intermediates
        if (maxHopsPerRouter >= 2) {
            // Limit to top intermediates to save gas
            uint maxIntermediates = intermediates.length > 10 ? 10 : intermediates.length;
            
            for (uint i = 0; i < maxIntermediates; i++) {
                address intermediate = intermediates[i];
                if (intermediate == address(0) || 
                    intermediate == inputToken || 
                    intermediate == outputToken ||
                    // Skip if already tried as special intermediate
                    intermediate == WETH ||
                    (stablecoins.length > 0 && intermediate == stablecoins[0]) ||
                    (stablecoins.length > 1 && intermediate == stablecoins[1])) {
                    continue;
                }
                
                address[] memory hopPath = new address[](3);
                hopPath[0] = inputToken;
                hopPath[1] = intermediate;
                hopPath[2] = outputToken;
                
                try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                    if (amounts.length > 2 && amounts[amounts.length - 1] > 0) {
                        if (amounts[amounts.length - 1] > expectedOutput) {
                            path = hopPath;
                            expectedOutput = amounts[amounts.length - 1];
                            hops = 2;
                        }
                    }
                } catch {
                    // Try next intermediate
                }
                
                // Optimization: Exit early if we've found a good 2-hop path
                // This saves gas while still finding good routes
                if (hops == 2 && i >= 3) {
                    break;
                }
            }
        }
        
        // Try 3-hop path (4 tokens total) - first try with special high-liquidity combinations
        if (maxHopsPerRouter >= 3 && expectedOutput == 0) {
            // First try WETH + stablecoin combination which often has good liquidity
            if (inputToken != WETH && outputToken != WETH && stablecoins.length > 0) {
                address[] memory hopPath = new address[](4);
                hopPath[0] = inputToken;
                hopPath[1] = WETH;
                hopPath[2] = stablecoins[0];
                hopPath[3] = outputToken;
                
                try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                    if (amounts.length > 3 && amounts[amounts.length - 1] > 0) {
                        if (amounts[amounts.length - 1] > expectedOutput) {
                            path = hopPath;
                            expectedOutput = amounts[amounts.length - 1];
                            hops = 3;
                        }
                    }
                } catch {
                    // Try reversed order
                }
                
                // Try reversed order (output -> stablecoin -> WETH -> input)
                hopPath[0] = inputToken;
                hopPath[1] = stablecoins[0];
                hopPath[2] = WETH;
                hopPath[3] = outputToken;
                
                try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                    if (amounts.length > 3 && amounts[amounts.length - 1] > 0) {
                        if (amounts[amounts.length - 1] > expectedOutput) {
                            path = hopPath;
                            expectedOutput = amounts[amounts.length - 1];
                            hops = 3;
                        }
                    }
                } catch {
                    // Try standard combinations
                }
            }
            
            // Try standard combinations with top ranked intermediates
            uint maxCombinations = 5; // Limit combinations to save gas
            uint combinationCount = 0;
            
            // Only use top ranked intermediates for 3-hop paths
            uint maxIntermediates = intermediates.length > 7 ? 7 : intermediates.length;
            
            for (uint i = 0; i < maxIntermediates && combinationCount < maxCombinations; i++) {
                address intermediate1 = intermediates[i];
                if (intermediate1 == address(0) || 
                    intermediate1 == inputToken || 
                    intermediate1 == outputToken) {
                    continue;
                }
                
                for (uint j = 0; j < maxIntermediates && combinationCount < maxCombinations; j++) {
                    if (i == j) continue;
                    
                    address intermediate2 = intermediates[j];
                    if (intermediate2 == address(0) || 
                        intermediate2 == inputToken || 
                        intermediate2 == outputToken ||
                        intermediate2 == intermediate1) {
                        continue;
                    }
                    
                    combinationCount++;
                    
                    address[] memory hopPath = new address[](4);
                    hopPath[0] = inputToken;
                    hopPath[1] = intermediate1;
                    hopPath[2] = intermediate2;
                    hopPath[3] = outputToken;
                    
                    try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                        if (amounts.length > 3 && amounts[amounts.length - 1] > 0) {
                            if (amounts[amounts.length - 1] > expectedOutput) {
                                path = hopPath;
                                expectedOutput = amounts[amounts.length - 1];
                                hops = 3;
                            }
                        }
                    } catch {
                        // Try next combination
                    }
                }
            }
        }
        
        // Only try 4-hop paths if we haven't found anything good yet
        // 4-hop paths are much less common but can be useful in certain cases
        if (maxHopsPerRouter >= 4 && expectedOutput == 0) {
            // Try specialized 4-hop path combinations that are more likely to be efficient
            // Focus on combinations using WETH and stablecoins
            
            if (inputToken != WETH && outputToken != WETH && stablecoins.length >= 2) {
                address[] memory hopPath = new address[](5);
                hopPath[0] = inputToken;
                hopPath[1] = WETH;
                hopPath[2] = stablecoins[0];
                hopPath[3] = stablecoins[1];
                hopPath[4] = outputToken;
                
                try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                    if (amounts.length > 4 && amounts[amounts.length - 1] > 0) {
                        if (amounts[amounts.length - 1] > expectedOutput) {
                            path = hopPath;
                            expectedOutput = amounts[amounts.length - 1];
                            hops = 4;
                        }
                    }
                } catch {
                    // Try next combination
                }
                
                // Try a couple more variations with key tokens
                if (intermediates.length > 0) {
                    hopPath[0] = inputToken;
                    hopPath[1] = intermediates[0];
                    hopPath[2] = WETH;
                    hopPath[3] = stablecoins[0];
                    hopPath[4] = outputToken;
                    
                    try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                        if (amounts.length > 4 && amounts[amounts.length - 1] > 0) {
                            if (amounts[amounts.length - 1] > expectedOutput) {
                                path = hopPath;
                                expectedOutput = amounts[amounts.length - 1];
                                hops = 4;
                            }
                        }
                    } catch {
                        // Try next combination
                    }
                }
            }
            
            // Try a limited number of combinations of top intermediates if nothing found yet
            if (expectedOutput == 0) {
                uint maxCombinations = 3; // Very limited to save gas
                uint combinationCount = 0;
                
                // Only use top ranked intermediates
                uint maxIntermediates = intermediates.length > 5 ? 5 : intermediates.length;
                
                for (uint i = 0; i < maxIntermediates && combinationCount < maxCombinations; i++) {
                    address intermediate1 = intermediates[i];
                    if (intermediate1 == address(0) || 
                        intermediate1 == inputToken || 
                        intermediate1 == outputToken) {
                        continue;
                    }
                    
                    for (uint j = 0; j < maxIntermediates && combinationCount < maxCombinations; j++) {
                        if (i == j) continue;
                        
                        address intermediate2 = intermediates[j];
                        if (intermediate2 == address(0) || 
                            intermediate2 == inputToken || 
                            intermediate2 == outputToken ||
                            intermediate2 == intermediate1) {
                            continue;
                        }
                        
                        for (uint k = 0; k < maxIntermediates && combinationCount < maxCombinations; k++) {
                            if (i == k || j == k) continue;
                            
                            address intermediate3 = intermediates[k];
                            if (intermediate3 == address(0) || 
                                intermediate3 == inputToken || 
                                intermediate3 == outputToken ||
                                intermediate3 == intermediate1 ||
                                intermediate3 == intermediate2) {
                                continue;
                            }
                            
                            combinationCount++;
                            
                            address[] memory hopPath = new address[](5);
                            hopPath[0] = inputToken;
                            hopPath[1] = intermediate1;
                            hopPath[2] = intermediate2;
                            hopPath[3] = intermediate3;
                            hopPath[4] = outputToken;
                            
                            try IUniswapV2Router02(router).getAmountsOut(10000, hopPath) returns (uint[] memory amounts) {
                                if (amounts.length > 4 && amounts[amounts.length - 1] > 0) {
                                    if (amounts[amounts.length - 1] > expectedOutput) {
                                        path = hopPath;
                                        expectedOutput = amounts[amounts.length - 1];
                                        hops = 4;
                                    }
                                }
                            } catch {
                                // Try next combination
                            }
                        }
                    }
                }
            }
        }
        
        // If we found a good path, try with the actual input amount
        if (path.length > 0 && expectedOutput > 0) {
            try IUniswapV2Router02(router).getAmountsOut(1e18, path) returns (uint[] memory amounts) {
                if (amounts.length > path.length - 1) {
                    expectedOutput = amounts[amounts.length - 1];
                }
            } catch {
                // Keep the existing output estimate
            }
        }
        
        return (path, expectedOutput, hops);
    }
    
    // Helper function to evaluate complex multi-router paths
    function findComplexMultiRouterPath(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint maxHops,
        uint maxHopsPerRouter,
        uint maxRouterUsage
    ) internal view returns (TradeRoute memory route, uint expectedOut) {
        if (maxHops < 2 || maxHops > MAX_HOPS) {
            return (route, 0);
        }
        
        route.inputToken = inputToken;
        route.outputToken = outputToken;
        route.hops = 0;
        expectedOut = 0;
        
        // Initialize router usage tracking
        RouterUsage[] memory routerUsages = new RouterUsage[](routers.length);
        for (uint i = 0; i < routers.length; i++) {
            routerUsages[i] = RouterUsage({
                router: routers[i],
                usageCount: 0
            });
        }
        
        // Get all possible intermediate tokens and rank them by liquidity
        address[] memory intermediates = getAllWhitelistedTokens();
        intermediates = rankIntermediateTokens(inputToken, outputToken, intermediates);
        
        // Start with first hop
        uint bestOutput = 0;
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        bestRoute.hops = maxHops;
        bestRoute.splitRoutes = new Split[][](maxHops);
        
        // Try specialized high-performance paths first
        // 1. WETH route for non-WETH pairs (most efficient on many DEXes)
        if (inputToken != WETH && outputToken != WETH) {
            // Try a two-hop path through WETH with multiple routers
            for (uint r1 = 0; r1 < routers.length; r1++) {
                address router1 = routers[r1];
                if (router1 == address(0)) continue;
                
                address[] memory firstHopPath = getPath(inputToken, WETH);
                uint firstHopOutput = 0;
                
                try IUniswapV2Router02(router1).getAmountsOut(amountIn, firstHopPath) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        firstHopOutput = amounts[amounts.length - 1];
                    }
                } catch {
                    continue;
                }
                
                if (firstHopOutput == 0) continue;
                
                // Try all routers for second hop including repeating the same router
                for (uint r2 = 0; r2 < routers.length; r2++) {
                    address router2 = routers[r2];
                    if (router2 == address(0)) continue;
                    
                    address[] memory secondHopPath = getPath(WETH, outputToken);
                    uint secondHopOutput = 0;
                    
                    try IUniswapV2Router02(router2).getAmountsOut(firstHopOutput, secondHopPath) returns (uint[] memory amounts) {
                        if (amounts.length > 1) {
                            secondHopOutput = amounts[amounts.length - 1];
                        }
                    } catch {
                        continue;
                    }
                    
                    if (secondHopOutput == 0) continue;
                    
                    if (secondHopOutput > bestOutput) {
                        bestOutput = secondHopOutput;
                        
                        bestRoute.hops = 2;
                        bestRoute.splitRoutes = new Split[][](2);
                        
                        bestRoute.splitRoutes[0] = new Split[](1);
                        bestRoute.splitRoutes[0][0] = Split({
                            router: router1,
                            percentage: 10000,
                            path: firstHopPath
                        });
                        
                        bestRoute.splitRoutes[1] = new Split[](1);
                        bestRoute.splitRoutes[1][0] = Split({
                            router: router2,
                            percentage: 10000,
                            path: secondHopPath
                        });
                    }
                }
            }
        }
        
        // 2. Try stablecoin bridges - these often have excellent liquidity
        address[] memory stablecoins = getCommonStablecoins();
        for (uint s = 0; s < stablecoins.length && s < 2; s++) { // Limit to first 2 stablecoins to save gas
            address stablecoin = stablecoins[s];
            if (stablecoin == address(0) || stablecoin == inputToken || stablecoin == outputToken) {
                continue;
            }
            
            for (uint r1 = 0; r1 < routers.length; r1++) {
                address router1 = routers[r1];
                if (router1 == address(0)) continue;
                
                address[] memory firstHopPath = getPath(inputToken, stablecoin);
                uint firstHopOutput = 0;
                
                try IUniswapV2Router02(router1).getAmountsOut(amountIn, firstHopPath) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        firstHopOutput = amounts[amounts.length - 1];
                    }
                } catch {
                    continue;
                }
                
                if (firstHopOutput == 0) continue;
                
                for (uint r2 = 0; r2 < routers.length; r2++) {
                    address router2 = routers[r2];
                    if (router2 == address(0)) continue;
                    
                    address[] memory secondHopPath = getPath(stablecoin, outputToken);
                    uint secondHopOutput = 0;
                    
                    try IUniswapV2Router02(router2).getAmountsOut(firstHopOutput, secondHopPath) returns (uint[] memory amounts) {
                        if (amounts.length > 1) {
                            secondHopOutput = amounts[amounts.length - 1];
                        }
                    } catch {
                        continue;
                    }
                    
                    if (secondHopOutput == 0) continue;
                    
                    if (secondHopOutput > bestOutput) {
                        bestOutput = secondHopOutput;
                        
                        bestRoute.hops = 2;
                        bestRoute.splitRoutes = new Split[][](2);
                        
                        bestRoute.splitRoutes[0] = new Split[](1);
                        bestRoute.splitRoutes[0][0] = Split({
                            router: router1,
                            percentage: 10000,
                            path: firstHopPath
                        });
                        
                        bestRoute.splitRoutes[1] = new Split[](1);
                        bestRoute.splitRoutes[1][0] = Split({
                            router: router2,
                            percentage: 10000,
                            path: secondHopPath
                        });
                    }
                }
            }
        }
        
        // Try each router for first hop with expanded paths inside individual routers
        for (uint r = 0; r < routers.length; r++) {
            address router = routers[r];
            if (router == address(0)) continue;
            
            // Try expanded path within this router (up to maxHopsPerRouter internal hops)
            address[] memory expandedPath;
            uint pathOutput;
            uint pathHops;
            (expandedPath, pathOutput, pathHops) = getExpandedPath(
                inputToken,
                outputToken,
                router,
                maxHopsPerRouter
            );
            
            if (pathOutput > 0 && expandedPath.length >= 2) {
                // Calculate actual output with amount
                uint realPathOutput = 0;
                try IUniswapV2Router02(router).getAmountsOut(amountIn, expandedPath) returns (uint[] memory amounts) {
                    if (amounts.length >= expandedPath.length) {
                        realPathOutput = amounts[amounts.length - 1];
                    }
                } catch {
                    realPathOutput = 0;
                }
                
                // This is a complete path, check if it's better than current best
                if (realPathOutput > bestOutput) {
                    bestOutput = realPathOutput;
                    
                    // Reset best route
                    bestRoute.hops = 1;
                    bestRoute.splitRoutes = new Split[][](1);
                    
                    // Add the expanded path as a single hop
                    bestRoute.splitRoutes[0] = new Split[](1);
                    bestRoute.splitRoutes[0][0] = Split({
                        router: router,
                        percentage: 10000,
                        path: expandedPath
                    });
                }
            }
            
            // Now try multi-hop routes with first hop using this router
            // Only check top intermediates to save gas (focus on most promising ones)
            uint maxIntermediates = intermediates.length > 10 ? 10 : intermediates.length;
            
            for (uint i = 0; i < maxIntermediates; i++) {
                address intermediate = intermediates[i];
                if (intermediate == address(0) || 
                    intermediate == inputToken || 
                    intermediate == outputToken) {
                    continue;
                }
                
                // Try expanded path for first hop
                address[] memory firstHopPath;
                uint firstHopOutput;
                uint firstHopCount;
                (firstHopPath, firstHopOutput, firstHopCount) = getExpandedPath(
                    inputToken,
                    intermediate,
                    router,
                    maxHopsPerRouter
                );
                
                if (firstHopOutput == 0 || firstHopPath.length < 2) continue;
                
                // Calculate actual output with amount
                uint realFirstHopOutput = 0;
                try IUniswapV2Router02(router).getAmountsOut(amountIn, firstHopPath) returns (uint[] memory amounts) {
                    if (amounts.length >= firstHopPath.length) {
                        realFirstHopOutput = amounts[amounts.length - 1];
                    }
                } catch {
                    continue;
                }
                
                if (realFirstHopOutput == 0) continue;
                
                // Track router usage for this path
                RouterUsage[] memory pathUsages = new RouterUsage[](routers.length);
                for (uint u = 0; u < routers.length; u++) {
                    pathUsages[u] = RouterUsage({
                        router: routers[u],
                        usageCount: 0
                    });
                }
                
                // Mark this router as used
                updateRouterUsage(router, pathUsages);
                
                // Try second hop with all routers (including the same one if allowed)
                for (uint r2 = 0; r2 < routers.length; r2++) {
                    address router2 = routers[r2];
                    if (router2 == address(0)) continue;
                    
                    // Check if we can use this router
                    if (!canUseRouter(router2, pathUsages, maxRouterUsage)) continue;
                    
                    // Try expanded path for second hop
                    address[] memory secondHopPath;
                    uint secondHopOutput;
                    uint secondHopCount;
                    (secondHopPath, secondHopOutput, secondHopCount) = getExpandedPath(
                        intermediate,
                        outputToken,
                        router2,
                        maxHopsPerRouter
                    );
                    
                    if (secondHopOutput == 0 || secondHopPath.length < 2) continue;
                    
                    // Calculate actual output with first hop amount
                    uint realSecondHopOutput = 0;
                    try IUniswapV2Router02(router2).getAmountsOut(realFirstHopOutput, secondHopPath) returns (uint[] memory amounts) {
                        if (amounts.length >= secondHopPath.length) {
                            realSecondHopOutput = amounts[amounts.length - 1];
                        }
                    } catch {
                        continue;
                    }
                    
                    if (realSecondHopOutput == 0) continue;
                    
                    // Check if this two-hop path is better than current best
                    if (realSecondHopOutput > bestOutput) {
                        bestOutput = realSecondHopOutput;
                        
                        // Reset best route
                        bestRoute.hops = 2;
                        bestRoute.splitRoutes = new Split[][](2);
                        
                        // Add the expanded paths
                        bestRoute.splitRoutes[0] = new Split[](1);
                        bestRoute.splitRoutes[0][0] = Split({
                            router: router,
                            percentage: 10000,
                            path: firstHopPath
                        });
                        
                        bestRoute.splitRoutes[1] = new Split[](1);
                        bestRoute.splitRoutes[1][0] = Split({
                            router: router2,
                            percentage: 10000,
                            path: secondHopPath
                        });
                    }
                    
                    // If we're looking for more than 2 hops, continue
                    if (maxHops <= 2) continue;
                    
                    // Update router usage for this path
                    RouterUsage[] memory thirdHopUsages = new RouterUsage[](routers.length);
                    for (uint u = 0; u < routers.length; u++) {
                        thirdHopUsages[u] = pathUsages[u];
                    }
                    updateRouterUsage(router2, thirdHopUsages);
                    
                    // Try specialized 3-hop paths using top stablecoins or WETH as second intermediate
                    address[] memory specialIntermediates = new address[](stablecoins.length + 1);
                    specialIntermediates[0] = WETH;
                    for (uint si = 0; si < stablecoins.length && si < specialIntermediates.length - 1; si++) {
                        specialIntermediates[si + 1] = stablecoins[si];
                    }
                    
                    // Try these special intermediates first (they often have better liquidity)
                    for (uint si = 0; si < specialIntermediates.length; si++) {
                        address intermediate2 = specialIntermediates[si];
                        if (intermediate2 == address(0) || 
                            intermediate2 == inputToken || 
                            intermediate2 == outputToken ||
                            intermediate2 == intermediate) {
                            continue;
                        }
                        
                        // Try third hop with optimal router search
                        for (uint r3 = 0; r3 < routers.length; r3++) {
                            address router3 = routers[r3];
                            if (router3 == address(0)) continue;
                            
                            // Check if we can use this router
                            if (!canUseRouter(router3, thirdHopUsages, maxRouterUsage)) continue;
                            
                            // Try expanded path for third hop
                            address[] memory thirdHopPath;
                            uint thirdHopOutput;
                            uint thirdHopCount;
                            (thirdHopPath, thirdHopOutput, thirdHopCount) = getExpandedPath(
                                intermediate,
                                intermediate2,
                                router3,
                                maxHopsPerRouter
                            );
                            
                            if (thirdHopOutput == 0 || thirdHopPath.length < 2) continue;
                            
                            uint realThirdHopOutput = 0;
                            try IUniswapV2Router02(router3).getAmountsOut(realSecondHopOutput, thirdHopPath) returns (uint[] memory amounts) {
                                if (amounts.length >= thirdHopPath.length) {
                                    realThirdHopOutput = amounts[amounts.length - 1];
                                }
                            } catch {
                                continue;
                            }
                            
                            if (realThirdHopOutput == 0) continue;
                            
                            // Try fourth hop with all routers
                            RouterUsage[] memory fourthHopUsages = new RouterUsage[](routers.length);
                            for (uint u = 0; u < routers.length; u++) {
                                fourthHopUsages[u] = thirdHopUsages[u];
                            }
                            updateRouterUsage(router3, fourthHopUsages);
                            
                            for (uint r4 = 0; r4 < routers.length; r4++) {
                                address router4 = routers[r4];
                                if (router4 == address(0)) continue;
                                
                                // Check if we can use this router
                                if (!canUseRouter(router4, fourthHopUsages, maxRouterUsage)) continue;
                                
                                // Try expanded path for fourth hop
                                address[] memory fourthHopPath;
                                uint fourthHopOutput;
                                uint fourthHopCount;
                                (fourthHopPath, fourthHopOutput, fourthHopCount) = getExpandedPath(
                                    intermediate2,
                                    outputToken,
                                    router4,
                                    maxHopsPerRouter
                                );
                                
                                if (fourthHopOutput == 0 || fourthHopPath.length < 2) continue;
                                
                                uint finalOutput = 0;
                                try IUniswapV2Router02(router4).getAmountsOut(realThirdHopOutput, fourthHopPath) returns (uint[] memory amounts) {
                                    if (amounts.length >= fourthHopPath.length) {
                                        finalOutput = amounts[amounts.length - 1];
                                    }
                                } catch {
                                    continue;
                                }
                                
                                if (finalOutput == 0) continue;
                                
                                // Check if this four-hop path is better than current best
                                if (finalOutput > bestOutput) {
                                    bestOutput = finalOutput;
                                    
                                    // Reset best route
                                    bestRoute.hops = 4;
                                    bestRoute.splitRoutes = new Split[][](4);
                                    
                                    // Add all hops
                                    bestRoute.splitRoutes[0] = new Split[](1);
                                    bestRoute.splitRoutes[0][0] = Split({
                                        router: router,
                                        percentage: 10000,
                                        path: firstHopPath
                                    });
                                    
                                    bestRoute.splitRoutes[1] = new Split[](1);
                                    bestRoute.splitRoutes[1][0] = Split({
                                        router: router2,
                                        percentage: 10000,
                                        path: secondHopPath
                                    });
                                    
                                    bestRoute.splitRoutes[2] = new Split[](1);
                                    bestRoute.splitRoutes[2][0] = Split({
                                        router: router3,
                                        percentage: 10000,
                                        path: thirdHopPath
                                    });
                                    
                                    bestRoute.splitRoutes[3] = new Split[](1);
                                    bestRoute.splitRoutes[3][0] = Split({
                                        router: router4,
                                        percentage: 10000,
                                        path: fourthHopPath
                                    });
                                }
                            }
                        }
                    }
                    
                    // Now try regular intermediates for third hop
                    // Limit to first several intermediates to save gas
                    uint maxThirdHopIntermediates = 5;
                    for (uint j = 0; j < intermediates.length && j < maxThirdHopIntermediates; j++) {
                        address intermediate2 = intermediates[j];
                        if (intermediate2 == address(0) || 
                            intermediate2 == inputToken || 
                            intermediate2 == outputToken ||
                            intermediate2 == intermediate ||
                            // Skip if already tried as special intermediate
                            intermediate2 == WETH ||
                            isStablecoin(intermediate2)) {
                            continue;
                        }
                        
                        // Try all routers for third hop
                        for (uint r3 = 0; r3 < routers.length; r3++) {
                            address router3 = routers[r3];
                            if (router3 == address(0)) continue;
                            
                            // Check if we can use this router
                            if (!canUseRouter(router3, thirdHopUsages, maxRouterUsage)) continue;
                            
                            // Try third hop with this router
                            address[] memory thirdHopPath = getPath(intermediate, intermediate2);
                            
                            uint thirdHopOutput = 0;
                            try IUniswapV2Router02(router3).getAmountsOut(realSecondHopOutput, thirdHopPath) returns (uint[] memory amounts) {
                                if (amounts.length > 1) {
                                    thirdHopOutput = amounts[amounts.length - 1];
                                }
                            } catch {
                                continue;
                            }
                            
                            if (thirdHopOutput == 0) continue;
                            
                            // Try fourth hop with all routers
                            RouterUsage[] memory fourthHopUsages = new RouterUsage[](routers.length);
                            for (uint u = 0; u < routers.length; u++) {
                                fourthHopUsages[u] = thirdHopUsages[u];
                            }
                            updateRouterUsage(router3, fourthHopUsages);
                            
                            for (uint r4 = 0; r4 < routers.length; r4++) {
                                address router4 = routers[r4];
                                if (router4 == address(0)) continue;
                                
                                // Check if we can use this router
                                if (!canUseRouter(router4, fourthHopUsages, maxRouterUsage)) continue;
                                
                                // Try fourth hop with this router
                                address[] memory fourthHopPath = getPath(intermediate2, outputToken);
                                
                                uint finalOutput = 0;
                                try IUniswapV2Router02(router4).getAmountsOut(thirdHopOutput, fourthHopPath) returns (uint[] memory amounts) {
                                    if (amounts.length > 1) {
                                        finalOutput = amounts[amounts.length - 1];
                                    }
                                } catch {
                                    continue;
                                }
                                
                                if (finalOutput == 0) continue;
                                
                                // Check if this four-hop path is better than current best
                                if (finalOutput > bestOutput) {
                                    bestOutput = finalOutput;
                                    
                                    // Reset best route
                                    bestRoute.hops = 4;
                                    bestRoute.splitRoutes = new Split[][](4);
                                    
                                    // Add all hops
                                    bestRoute.splitRoutes[0] = new Split[](1);
                                    bestRoute.splitRoutes[0][0] = Split({
                                        router: router,
                                        percentage: 10000,
                                        path: firstHopPath
                                    });
                                    
                                    bestRoute.splitRoutes[1] = new Split[](1);
                                    bestRoute.splitRoutes[1][0] = Split({
                                        router: router2,
                                        percentage: 10000,
                                        path: secondHopPath
                                    });
                                    
                                    bestRoute.splitRoutes[2] = new Split[](1);
                                    bestRoute.splitRoutes[2][0] = Split({
                                        router: router3,
                                        percentage: 10000,
                                        path: thirdHopPath
                                    });
                                    
                                    bestRoute.splitRoutes[3] = new Split[](1);
                                    bestRoute.splitRoutes[3][0] = Split({
                                        router: router4,
                                        percentage: 10000,
                                        path: fourthHopPath
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
        
        if (bestOutput > 0) {
            route = bestRoute;
            expectedOut = bestOutput;
        }
        
        return (route, expectedOut);
    }
    
    // Helper function to check if a token is a stablecoin
    function isStablecoin(address token) internal view returns (bool) {
        address[] memory stablecoins = getCommonStablecoins();
        for (uint i = 0; i < stablecoins.length; i++) {
            if (stablecoins[i] == token) {
                return true;
            }
        }
        return false;
    }
    
    // Function to try parallel multi-path routing for better output
    function findParallelMultiPathRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (TradeRoute memory route, uint expectedOut) {
        route.inputToken = inputToken;
        route.outputToken = outputToken;
        route.hops = 0;
        expectedOut = 0;
        
        // Get top routers for direct path
        address[] memory topDirectRouters;
        uint[] memory directOutputs;
        (topDirectRouters, directOutputs) = findTopRoutersForPair(
            amountIn,
            inputToken,
            outputToken,
            MAX_SPLITS_PER_HOP
        );
        
        // Check if we have good direct paths
        bool hasGoodDirectPaths = false;
        for (uint i = 0; i < topDirectRouters.length; i++) {
            if (topDirectRouters[i] != address(0) && directOutputs[i] > 0) {
                hasGoodDirectPaths = true;
                break;
            }
        }
        
        // If we have good direct paths, optimize them
        if (hasGoodDirectPaths) {
            (uint optimizedOutput, uint[] memory percentages) = optimizeSplitPercentages(
                amountIn,
                inputToken,
                outputToken,
                topDirectRouters
            );
            
            if (optimizedOutput > 0) {
                route.hops = 1;
                route.splitRoutes = new Split[][](1);
                
                // Count valid splits
                uint validSplitCount = 0;
                for (uint i = 0; i < topDirectRouters.length; i++) {
                    if (topDirectRouters[i] != address(0) && percentages[i] > 0) {
                        validSplitCount++;
                    }
                }
                
                route.splitRoutes[0] = new Split[](validSplitCount);
                uint splitIndex = 0;
                
                for (uint i = 0; i < topDirectRouters.length; i++) {
                    if (topDirectRouters[i] != address(0) && percentages[i] > 0) {
                        route.splitRoutes[0][splitIndex] = Split({
                            router: topDirectRouters[i],
                            percentage: percentages[i],
                            path: getPath(inputToken, outputToken)
                        });
                        splitIndex++;
                    }
                }
                
                expectedOut = optimizedOutput;
            }
        }
        
        // Try parallel paths through different intermediates
        address[] memory intermediates = getAllWhitelistedTokens();
        
        // Rank intermediates by liquidity
        intermediates = rankIntermediateTokens(inputToken, outputToken, intermediates);
        
        // Consider top intermediates only to save gas
        uint maxIntermediates = 5;
        
        // Try parallel 2-hop paths through different intermediates
        for (uint i = 0; i < intermediates.length && i < maxIntermediates; i++) {
            address intermediate = intermediates[i];
            if (intermediate == address(0) || 
                intermediate == inputToken || 
                intermediate == outputToken) {
                continue;
            }
            
            // Try this intermediate with different percentages
            uint[] memory splitPercents = new uint[](5);
            splitPercents[0] = 2000;  // 20%
            splitPercents[1] = 4000;  // 40%
            splitPercents[2] = 5000;  // 50%
            splitPercents[3] = 6000;  // 60%
            splitPercents[4] = 8000;  // 80%
            
            for (uint p = 0; p < splitPercents.length; p++) {
                uint percent = splitPercents[p];
                uint remainingPercent = 10000 - percent;
                
                // Split amountIn according to percentages
                uint amount1 = (amountIn * percent) / 10000;
                uint amount2 = amountIn - amount1;
                
                if (amount1 == 0 || amount2 == 0) continue;
                
                // First path: InputToken -> Intermediate -> OutputToken
                uint firstPathOutput = 0;
                
                // Find best router for first hop
                (address bestRouter1, uint hop1Output) = findBestRouterForPair(
                    amount1,
                    inputToken,
                    intermediate
                );
                
                if (bestRouter1 == address(0) || hop1Output == 0) continue;
                
                // Find best router for second hop
                (address bestRouter2, uint hop2Output) = findBestRouterForPair(
                    hop1Output,
                    intermediate,
                    outputToken
                );
                
                if (bestRouter2 == address(0) || hop2Output == 0) continue;
                
                firstPathOutput = hop2Output;
                
                // Second path: Direct from InputToken to OutputToken
                uint secondPathOutput = 0;
                
                // Find best router for direct path
                (address bestDirectRouter, uint directOutput) = findBestRouterForPair(
                    amount2,
                    inputToken,
                    outputToken
                );
                
                if (bestDirectRouter == address(0) || directOutput == 0) continue;
                
                secondPathOutput = directOutput;
                
                // Total output from both paths
                uint totalOutput = firstPathOutput + secondPathOutput;
                
                if (totalOutput > expectedOut) {
                    expectedOut = totalOutput;
                    
                    // Set up the route
                    route.hops = 2;
                    route.splitRoutes = new Split[][](2);
                    
                    // First hop: Split between direct path and intermediate path
                    route.splitRoutes[0] = new Split[](2);
                    route.splitRoutes[0][0] = Split({
                        router: bestRouter1,
                        percentage: percent,
                        path: getPath(inputToken, intermediate)
                    });
                    route.splitRoutes[0][1] = Split({
                        router: bestDirectRouter,
                        percentage: remainingPercent,
                        path: getPath(inputToken, outputToken)
                    });
                    
                    // Second hop: Only for the intermediate path
                    route.splitRoutes[1] = new Split[](1);
                    route.splitRoutes[1][0] = Split({
                        router: bestRouter2,
                        percentage: 10000,
                        path: getPath(intermediate, outputToken)
                    });
                }
            }
        }
        
        return (route, expectedOut);
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
        try this.findBestSplitForHop(
            amountIn,
            inputToken,
            outputToken,
            new address[](0)
        ) returns (uint directOutput, Split[] memory directSplits) {
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
        } catch {
            // Continue if direct route fails
        }

        // Try two-hop route through WETH if neither token is WETH
        if (inputToken != WETH && outputToken != WETH) {
            try this.findBestRouterForPair(
                amountIn,
                inputToken,
                WETH
            ) returns (address inToWethRouter, uint wethOutput) {
                
                if (wethOutput > 0 && inToWethRouter != address(0)) {
                    try this.findBestRouterForPair(
                        wethOutput,
                        WETH,
                        outputToken
                    ) returns (address wethToOutRouter, uint finalOutput) {
                        
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
                    } catch {
                        // Continue if second hop of WETH route fails
                    }
                }
            } catch {
                // Continue if WETH route fails
            }
        }
        
        // Try stablecoin routes with a more efficient approach
        try this.getCommonStablecoins() returns (address[] memory stablecoins) {
            for (uint i = 0; i < stablecoins.length && i < 2; i++) {  // Limit to first 2 stablecoins to save gas
                address stablecoin = stablecoins[i];
                if (stablecoin == address(0) || stablecoin == inputToken || stablecoin == outputToken || !isWhitelisted(stablecoin)) {
                    continue;
                }
                
                try this.findBestRouterForPair(
                    amountIn,
                    inputToken,
                    stablecoin
                ) returns (address bestRouterFirst, uint firstHopOutput) {
                    if (firstHopOutput > 0 && bestRouterFirst != address(0)) {
                        try this.findBestRouterForPair(
                            firstHopOutput,
                            stablecoin,
                            outputToken
                        ) returns (address bestRouterSecond, uint secondHopOutput) {
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
                        } catch {
                            // Continue if second hop fails
                        }
                    }
                } catch {
                    // Continue if first hop fails
                }
            }
        } catch {
            // Continue if stablecoin routes fail
        }
        
        // Try expanded multi-router paths
        TradeRoute memory complexRoute;
        uint complexOutput;
        (complexRoute, complexOutput) = findComplexMultiRouterPath(
            amountIn,
            inputToken,
            outputToken,
            MAX_HOPS,            // Up to 4 hops total
            4,                   // Up to 4 internal hops per router
            2                    // Each router can be used twice
        );
        
        if (complexOutput > expectedOut && complexRoute.hops > 0) {
            bestRoute = complexRoute;
            expectedOut = complexOutput;
        }
        
        // Try parallel multi-path routing
        TradeRoute memory parallelRoute;
        uint parallelOutput;
        (parallelRoute, parallelOutput) = findParallelMultiPathRoute(
            amountIn,
            inputToken,
            outputToken
        );
        
        if (parallelOutput > expectedOut && parallelRoute.hops > 0) {
            bestRoute = parallelRoute;
            expectedOut = parallelOutput;
        }
        
        // Only try two-hop route with custom method if we haven't found a good route yet
        if (expectedOut == 0 || expectedOut < amountIn / 2) {
            try this.findBestTwoHopRoute(
                amountIn,
                inputToken,
                outputToken,
                new address[](0)
            ) returns (uint twoHopOutput, TradeRoute memory twoHopRoute) {
                
                if (twoHopOutput > expectedOut && twoHopRoute.hops > 0) {
                    bestRoute = twoHopRoute;
                    expectedOut = twoHopOutput;
                }
            } catch {
                // Continue if two-hop route fails
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


    // Arrays to store configurable intermediate tokens and stablecoins
    address[] public commonIntermediates;
    address[] public commonStablecoins;

    // Events for token management
    event IntermediateTokenAdded(address indexed token);
    event IntermediateTokenRemoved(address indexed token);
    event StablecoinAdded(address indexed token);
    event StablecoinRemoved(address indexed token);

    /**
     * @dev Add common intermediate tokens that are frequently used in trade routes
     * @param tokens Array of token addresses to add
     */
    function addCommonIntermediates(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Token cannot be zero address");
            
            // Check if token is already in the list
            bool exists = false;
            for (uint j = 0; j < commonIntermediates.length; j++) {
                if (commonIntermediates[j] == tokens[i]) {
                    exists = true;
                    break;
                }
            }
            
            if (!exists) {
                commonIntermediates.push(tokens[i]);
                emit IntermediateTokenAdded(tokens[i]);
            }
        }
    }

    /**
     * @dev Remove a token from the common intermediates list
     * @param token Address of the token to remove
     */
    function removeCommonIntermediate(address token) external onlyOwner {
        for (uint i = 0; i < commonIntermediates.length; i++) {
            if (commonIntermediates[i] == token) {
                // Swap with the last element and pop
                commonIntermediates[i] = commonIntermediates[commonIntermediates.length - 1];
                commonIntermediates.pop();
                emit IntermediateTokenRemoved(token);
                break;
            }
        }
    }

    /**
     * @dev Add common stablecoins that are frequently used in trade routes
     * @param tokens Array of stablecoin addresses to add
     */
    function addCommonStablecoins(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Token cannot be zero address");
            
            // Check if token is already in the list
            bool exists = false;
            for (uint j = 0; j < commonStablecoins.length; j++) {
                if (commonStablecoins[j] == tokens[i]) {
                    exists = true;
                    break;
                }
            }
            
            if (!exists) {
                commonStablecoins.push(tokens[i]);
                emit StablecoinAdded(tokens[i]);
            }
        }
    }

    /**
     * @dev Remove a token from the common stablecoins list
     * @param token Address of the stablecoin to remove
     */
    function removeCommonStablecoin(address token) external onlyOwner {
        for (uint i = 0; i < commonStablecoins.length; i++) {
            if (commonStablecoins[i] == token) {
                // Swap with the last element and pop
                commonStablecoins[i] = commonStablecoins[commonStablecoins.length - 1];
                commonStablecoins.pop();
                emit StablecoinRemoved(token);
                break;
            }
        }
    }

    function getCommonIntermediates() internal view returns (address[] memory) {
        // Create an array with WETH + all configured intermediates
        address[] memory intermediates = new address[](commonIntermediates.length + 1);
        intermediates[0] = WETH; // Always include WETH as first intermediate
        
        for (uint i = 0; i < commonIntermediates.length; i++) {
            intermediates[i + 1] = commonIntermediates[i];
        }
        
        return intermediates;
    }

    function getCommonStablecoins() public view returns (address[] memory) {
        return commonStablecoins;
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
        uint[] memory tinyAmountOutputs = new uint[](splitRouters.length);
        uint[] memory smallAmountOutputs = new uint[](splitRouters.length);
        uint[] memory mediumAmountOutputs = new uint[](splitRouters.length);
        uint[] memory largeAmountOutputs = new uint[](splitRouters.length);
        
        uint totalPossibleOutput = 0;
        
        // Test with more granular amounts to better detect price impact curve
        uint tinyAmount = amountIn / 20;    // 5% of input amount
        uint smallAmount = amountIn / 10;   // 10% of input amount
        uint mediumAmount = amountIn / 2;   // 50% of input amount
        uint largeAmount = amountIn;        // 100% of input amount
        
        // Find valid routers and get outputs for different input sizes
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0)) {
                routerCount++;
                address[] memory path = getPath(tokenIn, tokenOut);
                if (path.length < 2) continue;
                
                // Test with tiny amount (5%) to better understand price curve at low volume
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(tinyAmount, path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        tinyAmountOutputs[i] = amounts[amounts.length - 1];
                    }
                } catch {
                    tinyAmountOutputs[i] = 0;
                }
                
                // Test with small amount (10%)
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(smallAmount, path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        smallAmountOutputs[i] = amounts[amounts.length - 1];
                    }
                } catch {
                    smallAmountOutputs[i] = 0;
                }
                
                // Test with medium amount (50%)
                try IUniswapV2Router02(splitRouters[i]).getAmountsOut(mediumAmount, path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        mediumAmountOutputs[i] = amounts[amounts.length - 1];
                    }
                } catch {
                    mediumAmountOutputs[i] = 0;
                }
                
                // Test with large amount (100%)
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
        
        // Calculate detailed price impact for each router at multiple points
        int[] memory priceImpacts = calculateDetailedPriceImpacts(
            tinyAmountOutputs,
            smallAmountOutputs, 
            mediumAmountOutputs, 
            largeAmountOutputs,
            tinyAmount,
            smallAmount,
            mediumAmount,
            largeAmount
        );

        // Create price efficiency scores - measuring output relative to input considering price impact
        uint[] memory efficiencyScores = new uint[](splitRouters.length);
        uint totalEfficiencyScore = 0;
        
        for (uint i = 0; i < splitRouters.length; i++) {
            if (routerOutputs[i] > 0) {
                // Higher output and lower price impact means better efficiency
                // The formula balances output size with price impact resistance
                int impact = priceImpacts[i] < 0 ? int(0) : priceImpacts[i];
                if (impact > 2000) impact = 2000; // Cap at 20%
                
                // Efficiency = output * (2000 - impact) / 2000
                // This gives more weight to routers with high output and low impact
                efficiencyScores[i] = (routerOutputs[i] * uint(2000 - impact)) / 2000;
                totalEfficiencyScore += efficiencyScores[i];
            }
        }

        // Analyze split potential - more sophisticated analysis based on efficiency and liquidity
        bool shouldSplit = analyzeSplitPotential(priceImpacts, routerOutputs);
        
        // Determine if we need fine-grained control for high price impact scenarios
        bool highImpactScenario = false;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (routerOutputs[i] > 0 && priceImpacts[i] > 500) { // > 5% impact
                highImpactScenario = true;
                break;
            }
        }
        
        // Set initial percentages based on calculated efficiency scores
        if (totalPossibleOutput > 0) {
            if (shouldSplit) {
                if (totalEfficiencyScore > 0) {
                    // Distribute based on efficiency scores (balances output with price impact)
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (routerOutputs[i] > 0) {
                            bestPercentages[i] = (efficiencyScores[i] * 10000) / totalEfficiencyScore;
                        }
                    }
                } else {
                    // Fallback to simpler output-based distribution
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (routerOutputs[i] > 0) {
                            bestPercentages[i] = (routerOutputs[i] * 10000) / totalPossibleOutput;
                        }
                    }
                }
                
                // For high price impact scenarios, calculate an optimized curve-based split
                if (highImpactScenario) {
                    address[] memory activeRouters = new address[](splitRouters.length);
                    uint activeCount = 0;
                    
                    // Find active routers
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (routerOutputs[i] > 0) {
                            activeRouters[activeCount++] = splitRouters[i];
                        }
                    }
                    
                    if (activeCount > 1) {
                        // Try different split ratios to optimize against the price impact curve
                        // For simplicity with 2 routers, try these precise splits
                        if (activeCount == 2) {
                            uint[] memory curveOptimizedSplits = new uint[](11);
                            curveOptimizedSplits[0] = 1000;  // 10/90 split
                            curveOptimizedSplits[1] = 2000;  // 20/80 split
                            curveOptimizedSplits[2] = 3000;  // 30/70 split
                            curveOptimizedSplits[3] = 4000;  // 40/60 split
                            curveOptimizedSplits[4] = 4500;  // 45/55 split
                            curveOptimizedSplits[5] = 5000;  // 50/50 split
                            curveOptimizedSplits[6] = 5500;  // 55/45 split
                            curveOptimizedSplits[7] = 6000;  // 60/40 split
                            curveOptimizedSplits[8] = 7000;  // 70/30 split
                            curveOptimizedSplits[9] = 8000;  // 80/20 split
                            curveOptimizedSplits[10] = 9000; // 90/10 split
                            
                            uint bestSplitOutput = 0;
                            uint bestSplitRatio = 5000; // Default to 50/50
                            
                            for (uint s = 0; s < curveOptimizedSplits.length; s++) {
                                uint splitRatio = curveOptimizedSplits[s];
                                uint remainingRatio = 10000 - splitRatio;
                                
                                uint[] memory testSplit = new uint[](splitRouters.length);
                                uint router1Index = splitRouters.length;
                                uint router2Index = splitRouters.length;
                                
                                // Find indices of the two active routers
                                for (uint i = 0; i < splitRouters.length; i++) {
                                    if (splitRouters[i] == activeRouters[0]) {
                                        router1Index = i;
                                    } else if (splitRouters[i] == activeRouters[1]) {
                                        router2Index = i;
                                    }
                                }
                                
                                if (router1Index < splitRouters.length && router2Index < splitRouters.length) {
                                    testSplit[router1Index] = splitRatio;
                                    testSplit[router2Index] = remainingRatio;
                                    
                                    uint splitOutput = calculateSplitOutput(
                                        amountIn,
                                        tokenIn,
                                        tokenOut,
                                        splitRouters,
                                        testSplit
                                    );
                                    
                                    if (splitOutput > bestSplitOutput) {
                                        bestSplitOutput = splitOutput;
                                        bestSplitRatio = splitRatio;
                                    }
                                }
                            }
                            
                            // If we found a better split ratio, use it
                            if (bestSplitOutput > 0) {
                                uint remainingRatio = 10000 - bestSplitRatio;
                                
                                // Reset percentages
                                for (uint i = 0; i < bestPercentages.length; i++) {
                                    bestPercentages[i] = 0;
                                }
                                
                                // Set the optimized split
                                for (uint i = 0; i < splitRouters.length; i++) {
                                    if (splitRouters[i] == activeRouters[0]) {
                                        bestPercentages[i] = bestSplitRatio;
                                    } else if (splitRouters[i] == activeRouters[1]) {
                                        bestPercentages[i] = remainingRatio;
                                    }
                                }
                            }
                        }
                        // For 3 or more active routers, the test distributions will handle it
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
                // Find router with highest efficiency for remainder
                uint maxEfficiency = 0;
                uint maxIndex = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (efficiencyScores[i] > maxEfficiency) {
                        maxEfficiency = efficiencyScores[i];
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

        // Try even more test distributions with finer granularity
        uint[][] memory testDistributions = generateImprovedTestDistributions(splitRouters, routerOutputs, efficiencyScores);
        
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
    
    // New function to calculate more detailed price impacts across multiple volume points
    function calculateDetailedPriceImpacts(
        uint[] memory tinyOutputs,
        uint[] memory smallOutputs,
        uint[] memory mediumOutputs,
        uint[] memory largeOutputs,
        uint tinyAmount,
        uint smallAmount,
        uint mediumAmount,
        uint largeAmount
    ) internal pure returns (int[] memory impacts) {
        impacts = new int[](tinyOutputs.length);
        
        for (uint i = 0; i < tinyOutputs.length; i++) {
            if (tinyOutputs[i] == 0 || smallOutputs[i] == 0 || 
                mediumOutputs[i] == 0 || largeOutputs[i] == 0) {
                impacts[i] = 10000; // 100% impact (effectively infinite) for invalid routes
                continue;
            }
            
            // Calculate rates at each volume point
            uint tinyRate = (tinyOutputs[i] * 1e18) / tinyAmount;
            uint smallRate = (smallOutputs[i] * 1e18) / smallAmount;
            uint mediumRate = (mediumOutputs[i] * 1e18) / mediumAmount;
            uint largeRate = (largeOutputs[i] * 1e18) / largeAmount;
            
            // Calculate linear expectation vs actual outcome
            uint expectedLargeOutput = (tinyOutputs[i] * largeAmount) / tinyAmount;
            
            // Calculate price impact between tiny and large amounts
            if (tinyRate > largeRate && expectedLargeOutput > largeOutputs[i]) {
                uint impactRaw = ((expectedLargeOutput - largeOutputs[i]) * 10000) / expectedLargeOutput;
                impacts[i] = int(impactRaw);
            } else {
                impacts[i] = 0; // No price impact or positive rate (unusual but possible)
            }
            
            // Incorporate slope of the price impact curve
            // If the impact is accelerating (gets worse faster at higher volumes),
            // increase the reported impact to encourage smaller allocations
            if (tinyRate > smallRate && smallRate > mediumRate && mediumRate > largeRate) {
                // Calculate slope acceleration
                int smallToTinyDiff = int(tinyRate - smallRate) * 100 / int(tinyRate);
                int mediumToSmallDiff = int(smallRate - mediumRate) * 100 / int(smallRate);
                int largeToMediumDiff = int(mediumRate - largeRate) * 100 / int(mediumRate);
                
                // If slopes are increasing (accelerating price impact), adjust impact value
                if (largeToMediumDiff > mediumToSmallDiff && mediumToSmallDiff > smallToTinyDiff) {
                    // Add up to 20% based on how aggressive the curve is
                    int acceleration = (largeToMediumDiff - smallToTinyDiff) / 2;
                    if (acceleration > 200) acceleration = 200; // Cap at 2%
                    
                    impacts[i] += acceleration;
                }
            }
            
            // Ensure impact is reasonable
            if (impacts[i] < 0) impacts[i] = 0;
            if (impacts[i] > 5000) impacts[i] = 5000; // Cap at 50%
        }
        
        return impacts;
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
    
    // Generate improved test distributions with more granularity to find optimal split
    function generateImprovedTestDistributions(
        address[] memory splitRouters, 
        uint[] memory routerOutputs,
        uint[] memory efficiencyScores
    ) internal pure returns (uint[][] memory) {
        uint routerCount = 0;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0) && routerOutputs[i] > 0) {
                routerCount++;
            }
        }
        
        // Create array of test distributions with more options
        uint[][] memory testDistributions = new uint[][](50);
        
        // Find top routers by both raw output and efficiency
        uint[] memory topIndices = new uint[](4); // Store up to top 4 routers by output
        uint[] memory topOutputs = new uint[](4);
        uint[] memory topEffIndices = new uint[](4); // Store up to top 4 routers by efficiency
        uint[] memory topEffScores = new uint[](4);
        
        // Find top routers by output
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
        
        // Find top routers by efficiency
        for (uint i = 0; i < efficiencyScores.length; i++) {
            if (efficiencyScores[i] > topEffScores[0]) {
                // Shift everything down
                topEffScores[3] = topEffScores[2];
                topEffIndices[3] = topEffIndices[2];
                topEffScores[2] = topEffScores[1];
                topEffIndices[2] = topEffIndices[1];
                topEffScores[1] = topEffScores[0];
                topEffIndices[1] = topEffIndices[0];
                topEffScores[0] = efficiencyScores[i];
                topEffIndices[0] = i;
            } else if (efficiencyScores[i] > topEffScores[1]) {
                // Shift from 1 down
                topEffScores[3] = topEffScores[2];
                topEffIndices[3] = topEffIndices[2];
                topEffScores[2] = topEffScores[1];
                topEffIndices[2] = topEffIndices[1];
                topEffScores[1] = efficiencyScores[i];
                topEffIndices[1] = i;
            } else if (efficiencyScores[i] > topEffScores[2]) {
                // Shift from 2 down
                topEffScores[3] = topEffScores[2];
                topEffIndices[3] = topEffIndices[2];
                topEffScores[2] = efficiencyScores[i];
                topEffIndices[2] = i;
            } else if (efficiencyScores[i] > topEffScores[3]) {
                topEffScores[3] = efficiencyScores[i];
                topEffIndices[3] = i;
            }
        }
        
        // 100% to best router by output
        testDistributions[0] = new uint[](splitRouters.length);
        testDistributions[0][topIndices[0]] = 10000;
        
        // 100% to best router by efficiency (if different)
        if (topEffIndices[0] != topIndices[0]) {
            testDistributions[1] = new uint[](splitRouters.length);
            testDistributions[1][topEffIndices[0]] = 10000;
        } else {
            // 100% to second-best router by output
            testDistributions[1] = new uint[](splitRouters.length);
            testDistributions[1][topIndices[1]] = 10000;
        }
        
        if (routerCount >= 2) {
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
            
            // Two-way splits between top routers by output with more granularity
            // Try increments of 2% instead of 5% for more precision
            uint distributionIndex = 3;
            for (uint percentageTop = 98; percentageTop >= 52; percentageTop -= 2) {
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = percentageTop * 100;
                testDistributions[distributionIndex][topIndices[1]] = (100 - percentageTop) * 100;
                distributionIndex++;
                
                // Break if we're reaching array limit
                if (distributionIndex >= 26) break;
            }
            
            // If we have top routers by efficiency that differ from top by output,
            // try splits between those too
            if (topEffIndices[0] != topIndices[0] && topEffIndices[1] != topIndices[1] && 
                distributionIndex < 30) {
                
                // Two-way splits between top efficiency routers
                for (uint percentageTop = 90; percentageTop >= 50; percentageTop -= 10) {
                    testDistributions[distributionIndex] = new uint[](splitRouters.length);
                    testDistributions[distributionIndex][topEffIndices[0]] = percentageTop * 100;
                    testDistributions[distributionIndex][topEffIndices[1]] = (100 - percentageTop) * 100;
                    distributionIndex++;
                }
                
                // Mixed splits between top output and top efficiency router
                if (topEffIndices[0] != topIndices[0] && distributionIndex < 32) {
                    testDistributions[distributionIndex] = new uint[](splitRouters.length);
                    testDistributions[distributionIndex][topIndices[0]] = 7000;
                    testDistributions[distributionIndex][topEffIndices[0]] = 3000;
                    distributionIndex++;
                    
                    testDistributions[distributionIndex] = new uint[](splitRouters.length);
                    testDistributions[distributionIndex][topIndices[0]] = 5000;
                    testDistributions[distributionIndex][topEffIndices[0]] = 5000;
                    distributionIndex++;
                }
            }
            
            // Three-way splits with more options
            if (routerCount >= 3 && distributionIndex < 40) {
                // Classic three-way equal split
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 3334;
                testDistributions[distributionIndex][topIndices[1]] = 3333;
                testDistributions[distributionIndex][topIndices[2]] = 3333;
                distributionIndex++;
                
                // Progressive splits with more weight on better routers
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 5000;
                testDistributions[distributionIndex][topIndices[1]] = 3000;
                testDistributions[distributionIndex][topIndices[2]] = 2000;
                distributionIndex++;
                
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 6000;
                testDistributions[distributionIndex][topIndices[1]] = 2500;
                testDistributions[distributionIndex][topIndices[2]] = 1500;
                distributionIndex++;
                
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 7000;
                testDistributions[distributionIndex][topIndices[1]] = 2000;
                testDistributions[distributionIndex][topIndices[2]] = 1000;
                distributionIndex++;
                
                // Focus more on second router
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 4000;
                testDistributions[distributionIndex][topIndices[1]] = 5000;
                testDistributions[distributionIndex][topIndices[2]] = 1000;
                distributionIndex++;
                
                // Try with efficiency-based top routers if different
                if (topEffIndices[0] != topIndices[0] && topEffIndices[1] != topIndices[1] && 
                    distributionIndex < 46) {
                    testDistributions[distributionIndex] = new uint[](splitRouters.length);
                    testDistributions[distributionIndex][topEffIndices[0]] = 4000;
                    testDistributions[distributionIndex][topEffIndices[1]] = 4000;
                    testDistributions[distributionIndex][topEffIndices[2]] = 2000;
                    distributionIndex++;
                }
            }
            
            // Four-way splits for advanced diversification
            if (routerCount >= 4 && distributionIndex < 48) {
                // Equal four-way
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 2500;
                testDistributions[distributionIndex][topIndices[1]] = 2500;
                testDistributions[distributionIndex][topIndices[2]] = 2500;
                testDistributions[distributionIndex][topIndices[3]] = 2500;
                distributionIndex++;
                
                // Progressive weight distribution
                testDistributions[distributionIndex] = new uint[](splitRouters.length);
                testDistributions[distributionIndex][topIndices[0]] = 4000;
                testDistributions[distributionIndex][topIndices[1]] = 3000;
                testDistributions[distributionIndex][topIndices[2]] = 2000;
                testDistributions[distributionIndex][topIndices[3]] = 1000;
                distributionIndex++;
            }
        }
        
        // Dynamic weighted distributions based on output ratios
        testDistributions[48] = new uint[](splitRouters.length);
        if (routerCount > 0 && topOutputs[0] > 0) {
            uint totalWeight = 0;
            
            for (uint i = 0; i < splitRouters.length; i++) {
                if (routerOutputs[i] > 0) {
                    // Weight by square root of output (less aggressive than direct proportion)
                    testDistributions[48][i] = sqrt(routerOutputs[i] * 1e6);
                    totalWeight += testDistributions[48][i];
                }
            }
            
            if (totalWeight > 0) {
                // Normalize to 10000
                uint normalizedTotal = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (testDistributions[48][i] > 0) {
                        testDistributions[48][i] = (testDistributions[48][i] * 10000) / totalWeight;
                        normalizedTotal += testDistributions[48][i];
                    }
                }
                
                // Adjust for rounding
                if (normalizedTotal < 10000 && topIndices[0] < splitRouters.length) {
                    testDistributions[48][topIndices[0]] += (10000 - normalizedTotal);
                }
            }
        }
        
        // Dynamic distribution based on efficiency scores
        testDistributions[49] = new uint[](splitRouters.length);
        if (routerCount > 0) {
            uint totalEfficiency = 0;
            
            for (uint i = 0; i < splitRouters.length; i++) {
                if (efficiencyScores[i] > 0) {
                    // Use efficiency scores directly for weighting
                    testDistributions[49][i] = efficiencyScores[i];
                    totalEfficiency += efficiencyScores[i];
                }
            }
            
            if (totalEfficiency > 0) {
                // Normalize to 10000
                uint normalizedTotal = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (testDistributions[49][i] > 0) {
                        testDistributions[49][i] = (testDistributions[49][i] * 10000) / totalEfficiency;
                        normalizedTotal += testDistributions[49][i];
                    }
                }
                
                // Adjust for rounding
                if (normalizedTotal < 10000 && topEffIndices[0] < splitRouters.length) {
                    testDistributions[49][topEffIndices[0]] += (10000 - normalizedTotal);
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
