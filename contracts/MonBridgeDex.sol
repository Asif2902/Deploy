

// viaIR: true - To fix stack too deep errors
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Enable viaIR for optimization (helps with "Stack too deep" errors)
// pragma experimental ABIEncoderV2;


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
    
    // Tracking executed routes for optimization
    mapping(bytes32 => uint) public routePerformance;

    uint public constant FEE_DIVISOR = 1000; 
    uint public feeAccumulatedETH;
    mapping(address => uint) public feeAccumulatedTokens;
    address public WETH;

    mapping(address => bool) public whitelistedTokens;
    // Map to keep track of common bridge tokens for multi-hop trades
    mapping(address => uint) public bridgeTokenWeights;
    address[] public bridgeTokens;

    // Keep track of recent trade path performance for dynamic optimization
    struct PathPerformance {
        address[] path;
        uint lastTradedTimeStamp;
        uint successCount;
        uint failCount;
        uint averageReturn; // Basis points relative to direct route
    }

    mapping(bytes32 => PathPerformance) public pathPerformanceHistory;

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
    event BridgeTokenAdded(address token, uint weight);
    event BridgeTokenRemoved(address token);
    event PathPerformanceUpdated(bytes32 pathId, uint successCount, uint failCount, uint averageReturn);

    constructor(address _weth) {
        owner = msg.sender;
        WETH = _weth;
        whitelistedTokens[_weth] = true;
        // Add WETH as a default bridge token with high weight
        addBridgeToken(_weth, 1000);
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

    // Add a new function to manage bridge tokens with weight
    function addBridgeToken(address token, uint weight) public onlyOwner {
        require(token != address(0), "Invalid token address");
        require(weight > 0, "Weight must be greater than 0");
        
        if (bridgeTokenWeights[token] == 0) {
            bridgeTokens.push(token);
        }
        
        bridgeTokenWeights[token] = weight;
        // Make sure the token is whitelisted
        if (!whitelistedTokens[token]) {
            whitelistedTokens[token] = true;
            emit TokenWhitelisted(token);
        }
        emit BridgeTokenAdded(token, weight);
    }

    function removeBridgeToken(address token) external onlyOwner {
        require(bridgeTokenWeights[token] > 0, "Token not a bridge token");
        
        delete bridgeTokenWeights[token];
        
        // Remove from array
        for (uint i = 0; i < bridgeTokens.length; i++) {
            if (bridgeTokens[i] == token) {
                bridgeTokens[i] = bridgeTokens[bridgeTokens.length - 1];
                bridgeTokens.pop();
                break;
            }
        }
        
        emit BridgeTokenRemoved(token);
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

    // Get bridge tokens sorted by weight for efficient routing
    function getBridgeTokens() external view returns (address[] memory, uint[] memory) {
        address[] memory tokens = new address[](bridgeTokens.length);
        uint[] memory weights = new uint[](bridgeTokens.length);
        
        for (uint i = 0; i < bridgeTokens.length; i++) {
            tokens[i] = bridgeTokens[i];
            weights[i] = bridgeTokenWeights[bridgeTokens[i]];
        }
        
        return (tokens, weights);
    }

    // Calculate price impact for a trade
    function calculatePriceImpact(
        uint amountIn,
        uint amountOut,
        address inputToken,
        address outputToken
    ) public view returns (uint priceImpactBps) {
        // Get input token decimals
        uint8 inputDecimals = IERC20(inputToken).decimals();
        uint8 outputDecimals = IERC20(outputToken).decimals();
        
        // Normalize for decimal differences
        uint normalizedInput = amountIn;
        uint normalizedOutput = amountOut;
        
        if (inputDecimals > outputDecimals) {
            normalizedOutput = normalizedOutput * (10**(inputDecimals - outputDecimals));
        } else if (outputDecimals > inputDecimals) {
            normalizedInput = normalizedInput * (10**(outputDecimals - inputDecimals));
        }
        
        // Calculate price impact in basis points (10000 = 100%)
        // Lower output than expected = higher price impact
        if (normalizedInput == 0) return 0;
        
        uint priceRatio = (normalizedOutput * 10000) / normalizedInput;
        if (priceRatio >= 10000) {
            return 0; // No price impact or positive (arbitrage)
        }
        
        return 10000 - priceRatio;
    }
    
    // Generate path hash for performance tracking
    function getPathHash(address[] memory path) internal pure returns (bytes32) {
        return keccak256(abi.encode(path));
    }
    
    // Helper function to check if an array contains an address
    function containsAddress(address[] memory array, address addr) internal pure returns (bool) {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == addr) {
                return true;
            }
        }
        return false;
    }

    // Update path performance after execution
    function updatePathPerformance(address[] memory path, bool success, uint performanceMetric) internal {
        bytes32 pathId = getPathHash(path);
        PathPerformance storage perf = pathPerformanceHistory[pathId];
        
        if (perf.path.length == 0) {
            perf.path = path;
        }
        
        perf.lastTradedTimeStamp = block.timestamp;
        
        if (success) {
            perf.successCount++;
            // Update rolling average (weight recent performance more)
            perf.averageReturn = (perf.averageReturn * 3 + performanceMetric) / 4;
        } else {
            perf.failCount++;
            // Decrease the average slightly on failure
            if (perf.averageReturn > 0) {
                perf.averageReturn = (perf.averageReturn * 9) / 10;
            }
        }
        
        emit PathPerformanceUpdated(pathId, perf.successCount, perf.failCount, perf.averageReturn);
    }

    // Calculate dynamic path based on the tokens
    function getPath(address tokenA, address tokenB) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        return path;
    }

    // Dynamically build a path that may include intermediate tokens
    function buildPath(address tokenA, address tokenB, address[] memory intermediateTokens) internal pure returns (address[] memory) {
        address[] memory path = new address[](2 + intermediateTokens.length);
        path[0] = tokenA;
        
        for (uint i = 0; i < intermediateTokens.length; i++) {
            path[i+1] = intermediateTokens[i];
        }
        
        path[path.length - 1] = tokenB;
        return path;
    }

    // Dynamic path resolution with weighting based on historical performance
    function findDynamicPath(
        address router,
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (address[] memory bestPath, uint bestOutput) {
        // Start with direct path
        address[] memory directPath = getPath(inputToken, outputToken);
        
        try IUniswapV2Router02(router).getAmountsOut(amountIn, directPath) returns (uint[] memory amounts) {
            bestPath = directPath;
            bestOutput = amounts[amounts.length - 1];
        } catch {
            // If direct path fails, bestOutput remains 0
        }
        
        // Try all available bridge tokens for 2-hop routes
        for (uint i = 0; i < bridgeTokens.length; i++) {
            address bridgeToken = bridgeTokens[i];
            
            // Skip tokens that are the same as input or output
            if (bridgeToken == inputToken || bridgeToken == outputToken) {
                continue;
            }
            
            address[] memory path = new address[](3);
            path[0] = inputToken;
            path[1] = bridgeToken;
            path[2] = outputToken;
            
            try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                uint output = amounts[amounts.length - 1];
                
                // Apply weight factor from bridge token (in basis points)
                uint weight = bridgeTokenWeights[bridgeToken];
                if (weight > 0) {
                    // Adjust by at most ±2.5% based on weight (weight ranges from 1 to 1000)
                    output = (output * (9750 + (weight * 5) / 100)) / 10000;
                }
                
                // Check historical performance boost
                bytes32 pathId = getPathHash(path);
                PathPerformance storage perf = pathPerformanceHistory[pathId];
                if (perf.successCount > 0) {
                    // Successful paths get boosted slightly in the algorithm
                    uint successRatio = (perf.successCount * 10000) / (perf.successCount + perf.failCount);
                    // Maximum 1% boost for perfect history
                    output = (output * (10000 + successRatio / 100)) / 10000;
                }
                
                if (output > bestOutput) {
                    bestPath = path;
                    bestOutput = output;
                }
            } catch {
                // Continue if this path fails
            }
        }
        
        // Try 3-hop paths (with double bridge tokens) for potentially better routes
        if (bridgeTokens.length >= 2) {
            for (uint i = 0; i < bridgeTokens.length; i++) {
                address bridgeToken1 = bridgeTokens[i];
                
                // Skip if first bridge token is same as input or output
                if (bridgeToken1 == inputToken || bridgeToken1 == outputToken) {
                    continue;
                }
                
                for (uint j = 0; j < bridgeTokens.length; j++) {
                    // Allow same bridge token to be used if it has a good historical performance
                    // This is a key improvement allowing same token multiple times in path
                    if (i == j) {
                        bytes32 reusedPathId = getPathHash(new address[](0));
                        PathPerformance storage reusedPerf = pathPerformanceHistory[reusedPathId];
                        if (reusedPerf.successCount < 3 || reusedPerf.failCount > reusedPerf.successCount) {
                            continue; // Skip unless proven successful
                        }
                    }
                    
                    address bridgeToken2 = bridgeTokens[j];
                    
                    // Skip if second bridge token is same as input or output
                    if (bridgeToken2 == inputToken || bridgeToken2 == outputToken) {
                        continue;
                    }
                    
                    // Try 4-token path (Input -> Bridge1 -> Bridge2 -> Output)
                    address[] memory path = new address[](4);
                    path[0] = inputToken;
                    path[1] = bridgeToken1;
                    path[2] = bridgeToken2;
                    path[3] = outputToken;
                    
                    try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                        uint output = amounts[amounts.length - 1];
                        
                        // Check historical performance - complex paths need more validation
                        bytes32 pathId = getPathHash(path);
                        PathPerformance storage perf = pathPerformanceHistory[pathId];
                        
                        // Apply slight discount for complex paths to account for gas costs
                        // unless they have proven to be efficient
                        if (perf.successCount == 0 || perf.failCount > 0) {
                            // Apply a 0.5% discount for unproven complex paths
                            output = (output * 9950) / 10000;
                        }
                        
                        if (output > bestOutput) {
                            bestPath = path;
                            bestOutput = output;
                        }
                    } catch {
                        // Continue if this path fails
                    }
                }
            }
        }
        
        // Try 4-hop paths with triple bridge tokens for highly efficient routing
        if (bridgeTokens.length >= 3 && bestOutput > 0) {
            // Only try 4-hop paths if we've found a good path already, and only with top bridges
            uint topBridgeCount = bridgeTokens.length > 3 ? 3 : bridgeTokens.length;
            
            for (uint i = 0; i < topBridgeCount; i++) {
                address bridgeToken1 = bridgeTokens[i];
                if (bridgeToken1 == inputToken || bridgeToken1 == outputToken) continue;
                
                for (uint j = 0; j < topBridgeCount; j++) {
                    address bridgeToken2 = bridgeTokens[j];
                    if (bridgeToken2 == inputToken || bridgeToken2 == outputToken) continue;
                    
                    for (uint k = 0; k < topBridgeCount; k++) {
                        address bridgeToken3 = bridgeTokens[k];
                        if (bridgeToken3 == inputToken || bridgeToken3 == outputToken) continue;
                        
                        // Allow some duplicates as they can lead to better rates
                        if (bridgeToken1 == bridgeToken2 && bridgeToken2 == bridgeToken3) continue;
                        
                        // Try 5-token path (Input -> Bridge1 -> Bridge2 -> Bridge3 -> Output)
                        address[] memory path = new address[](5);
                        path[0] = inputToken;
                        path[1] = bridgeToken1;
                        path[2] = bridgeToken2;
                        path[3] = bridgeToken3;
                        path[4] = outputToken;
                        
                        try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                            uint output = amounts[amounts.length - 1];
                            
                            // Apply larger discount for very complex paths
                            output = (output * 9900) / 10000; // 1% discount for complexity
                            
                            if (output > bestOutput) {
                                bestPath = path;
                                bestOutput = output;
                            }
                        } catch {
                            // Continue if this path fails
                        }
                    }
                }
            }
        }
        
        // Try alternative patterns like triangular arbitrage
        // This pattern can sometimes yield better results due to pool imbalances
        if (bestOutput > 0 && bridgeTokens.length > 0) {
            for (uint i = 0; i < bridgeTokens.length && i < 3; i++) {
                address bridge = bridgeTokens[i];
                if (bridge == inputToken || bridge == outputToken) continue;
                
                // Pattern: InputToken -> Bridge -> OutputToken -> Bridge -> OutputToken
                address[] memory trianglePath = new address[](5);
                trianglePath[0] = inputToken;
                trianglePath[1] = bridge;
                trianglePath[2] = outputToken;
                trianglePath[3] = bridge;
                trianglePath[4] = outputToken;
                
                try IUniswapV2Router02(router).getAmountsOut(amountIn, trianglePath) returns (uint[] memory amounts) {
                    uint output = amounts[amounts.length - 1];
                    
                    // Apply gas cost discount
                    output = (output * 9950) / 10000; // 0.5% discount for complexity
                    
                    if (output > bestOutput) {
                        bestPath = trianglePath;
                        bestOutput = output;
                    }
                } catch {
                    // Continue if this path fails
                }
            }
            
            // Try alternative pattern: same token used at different positions
            // InputToken -> OutputToken -> Bridge -> OutputToken
            if (bestOutput > 0) {
                address bestBridge = bridgeTokens[0]; // Use the best bridge token
                
                if (bestBridge != inputToken && bestBridge != outputToken) {
                    address[] memory alternatePath = new address[](4);
                    alternatePath[0] = inputToken;
                    alternatePath[1] = outputToken;
                    alternatePath[2] = bestBridge;
                    alternatePath[3] = outputToken;
                    
                    try IUniswapV2Router02(router).getAmountsOut(amountIn, alternatePath) returns (uint[] memory amounts) {
                        uint output = amounts[amounts.length - 1];
                        
                        // Apply gas cost consideration
                        output = (output * 9975) / 10000;
                        
                        if (output > bestOutput) {
                            bestPath = alternatePath;
                            bestOutput = output;
                        }
                    } catch {
                        // Continue if this path fails
                    }
                }
            }
        }
        
        return (bestPath, bestOutput);
    }

    // Find best router for a given pair
    function findBestRouterForPair(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (address bestRouter, uint bestOutput) {
        bestOutput = 0;
        
        for (uint i = 0; i < routers.length; i++) {
            address router = routers[i];
            
            // Get the best dynamic path for this router
            address[] memory path;
            uint output;
            (path, output) = findDynamicPath(router, amountIn, inputToken, outputToken);
            
            if (output > bestOutput) {
                bestRouter = router;
                bestOutput = output;
            }
        }
        
        return (bestRouter, bestOutput);
    }

    // Find the best split for a single hop

    function findBestSplitForHop(
        uint amountIn,
        address inputToken,
        address outputToken,
        address[] memory excludeBridgeTokens
    ) external view returns (uint totalOutput, Split[] memory bestSplits) {
        totalOutput = 0;
        bestSplits = new Split[](MAX_SPLITS_PER_HOP);
        uint splitCount = 0;
        
        // Enhanced approach: track routers with their best paths
        address[] memory candidateRouters = new address[](routers.length * 2); // Extra space for same router with different paths
        address[][] memory candidatePaths = new address[][](routers.length * 2);
        uint[] memory candidateOutputs = new uint[](routers.length * 2);
        
        uint candidateCount = 0;
        
        // First, get all potential routes with their outputs
        for (uint i = 0; i < routers.length; i++) {
            address router = routers[i];
            
            // Get the best path for this router using our advanced path finding
            (address[] memory path, uint output) = findDynamicPath(router, amountIn, inputToken, outputToken);
            
            if (output > 0) {
                candidateRouters[candidateCount] = router;
                candidatePaths[candidateCount] = path;
                candidateOutputs[candidateCount] = output;
                candidateCount++;
            }
            
            // Try to find alternative paths using the same router (key improvement)
            // This allows the same router to be used multiple times with different paths
            for (uint j = 0; j < bridgeTokens.length && j < 3 && candidateCount < candidateRouters.length; j++) {
                address bridgeToken = bridgeTokens[j];
                
                // Skip invalid bridge tokens
                if (bridgeToken == inputToken || bridgeToken == outputToken || 
                    containsAddress(excludeBridgeTokens, bridgeToken)) {
                    continue;
                }
                
                address[] memory altPath = new address[](3);
                altPath[0] = inputToken;
                altPath[1] = bridgeToken;
                altPath[2] = outputToken;
                
                // Check if this is a duplicate of the main path
                bool isDuplicate = false;
                if (path.length == altPath.length) {
                    isDuplicate = true;
                    for (uint k = 0; k < path.length; k++) {
                        if (path[k] != altPath[k]) {
                            isDuplicate = false;
                            break;
                        }
                    }
                }
                
                if (!isDuplicate) {
                    try IUniswapV2Router02(router).getAmountsOut(amountIn, altPath) returns (uint[] memory amounts) {
                        uint altOutput = amounts[amounts.length - 1];
                        
                        // Only consider if output is meaningful (at least 99% of the best output for this router)
                        if (altOutput > 0 && (output == 0 || altOutput > output * 9900 / 10000)) {
                            candidateRouters[candidateCount] = router;
                            candidatePaths[candidateCount] = altPath;
                            candidateOutputs[candidateCount] = altOutput;
                            candidateCount++;
                        }
                    } catch {
                        // Continue if alternative path fails
                    }
                }
            }
            
            // Try a 3-hop path for even better routing if we have bridge tokens
            if (bridgeTokens.length >= 2 && candidateCount < candidateRouters.length) {
                for (uint j = 0; j < bridgeTokens.length && j < 2; j++) {
                    for (uint k = 0; k < bridgeTokens.length && k < 2; k++) {
                        if (j == k) continue; // Avoid using same bridge token twice in sequence
                        
                        address bridge1 = bridgeTokens[j];
                        address bridge2 = bridgeTokens[k];
                        
                        // Skip invalid bridge tokens
                        if (bridge1 == inputToken || bridge1 == outputToken || 
                            bridge2 == inputToken || bridge2 == outputToken || 
                            containsAddress(excludeBridgeTokens, bridge1) || 
                            containsAddress(excludeBridgeTokens, bridge2)) {
                            continue;
                        }
                        
                        address[] memory complexPath = new address[](4);
                        complexPath[0] = inputToken;
                        complexPath[1] = bridge1;
                        complexPath[2] = bridge2;
                        complexPath[3] = outputToken;
                        
                        try IUniswapV2Router02(router).getAmountsOut(amountIn, complexPath) returns (uint[] memory amounts) {
                            uint complexOutput = amounts[amounts.length - 1];
                            
                            // Apply a small discount for complex paths (gas cost consideration)
                            complexOutput = (complexOutput * 9980) / 10000; // 0.2% discount
                            
                            // Only consider if output is meaningful
                            if (complexOutput > 0 && (output == 0 || complexOutput > output * 9950 / 10000)) {
                                candidateRouters[candidateCount] = router;
                                candidatePaths[candidateCount] = complexPath;
                                candidateOutputs[candidateCount] = complexOutput;
                                candidateCount++;
                                
                                if (candidateCount >= candidateRouters.length) break;
                            }
                        } catch {
                            // Continue if this path fails
                        }
                    }
                    if (candidateCount >= candidateRouters.length) break;
                }
            }
        }
        
        // If no valid routes found, return early
        if (candidateCount == 0) {
            return (0, bestSplits);
        }
        
        // Sort all candidates by output (highest first)
        for (uint i = 0; i < candidateCount; i++) {
            for (uint j = i + 1; j < candidateCount; j++) {
                if (candidateOutputs[j] > candidateOutputs[i]) {
                    // Swap outputs
                    uint tempOutput = candidateOutputs[i];
                    candidateOutputs[i] = candidateOutputs[j];
                    candidateOutputs[j] = tempOutput;
                    
                    // Swap routers
                    address tempRouter = candidateRouters[i];
                    candidateRouters[i] = candidateRouters[j];
                    candidateRouters[j] = tempRouter;
                    
                    // Swap paths
                    address[] memory tempPath = candidatePaths[i];
                    candidatePaths[i] = candidatePaths[j];
                    candidatePaths[j] = tempPath;
                }
            }
        }
        
        // Dynamic split optimization - Try different split configurations
        // Strategy 1: Single router (no split)
        uint singleRouterOutput = candidateOutputs[0];
        
        // Strategy 2: Two-router split with different percentages
        uint bestTwoRouterOutput = 0;
        uint bestTwoRouterSplit = 0;
        
        if (candidateCount >= 2) {
            // Test different percentage combinations from 50/50 to 90/10
            uint[] memory testSplits = new uint[](5);
            testSplits[0] = 5000; // 50/50
            testSplits[1] = 6000; // 60/40
            testSplits[2] = 7000; // 70/30
            testSplits[3] = 8000; // 80/20
            testSplits[4] = 9000; // 90/10
            
            for (uint s = 0; s < testSplits.length; s++) {
                uint splitPct = testSplits[s];
                uint amount1 = (amountIn * splitPct) / 10000;
                uint amount2 = amountIn - amount1;
                
                uint output1 = 0;
                uint output2 = 0;
                
                try IUniswapV2Router02(candidateRouters[0]).getAmountsOut(
                    amount1, 
                    candidatePaths[0]
                ) returns (uint[] memory amounts) {
                    output1 = amounts[amounts.length - 1];
                } catch {
                    continue; // Skip this split if simulation fails
                }
                
                try IUniswapV2Router02(candidateRouters[1]).getAmountsOut(
                    amount2, 
                    candidatePaths[1]
                ) returns (uint[] memory amounts) {
                    output2 = amounts[amounts.length - 1];
                } catch {
                    continue; // Skip this split if simulation fails
                }
                
                uint totalSplitOutput = output1 + output2;
                
                if (totalSplitOutput > bestTwoRouterOutput) {
                    bestTwoRouterOutput = totalSplitOutput;
                    bestTwoRouterSplit = splitPct;
                }
            }
        }
        
        // Strategy 3: Three-router split (fixed ratios to save gas)
        uint bestThreeRouterOutput = 0;
        uint[] memory bestThreeRouterSplits = new uint[](2);
        
        if (candidateCount >= 3) {
            // Common 3-way split ratios
            uint[3][3] memory threeWaySplits = [
                [uint(5000), 3000, 2000], // 50/30/20
                [uint(6000), 2500, 1500], // 60/25/15
                [uint(4000), 3000, 3000]  // 40/30/30
            ];
            
            for (uint s = 0; s < threeWaySplits.length; s++) {
                uint amount1 = (amountIn * threeWaySplits[s][0]) / 10000;
                uint amount2 = (amountIn * threeWaySplits[s][1]) / 10000;
                uint amount3 = amountIn - amount1 - amount2;
                
                uint output1 = 0;
                uint output2 = 0;
                uint output3 = 0;
                
                try IUniswapV2Router02(candidateRouters[0]).getAmountsOut(
                    amount1, 
                    candidatePaths[0]
                ) returns (uint[] memory amounts) {
                    output1 = amounts[amounts.length - 1];
                } catch {
                    continue;
                }
                
                try IUniswapV2Router02(candidateRouters[1]).getAmountsOut(
                    amount2, 
                    candidatePaths[1]
                ) returns (uint[] memory amounts) {
                    output2 = amounts[amounts.length - 1];
                } catch {
                    continue;
                }
                
                try IUniswapV2Router02(candidateRouters[2]).getAmountsOut(
                    amount3, 
                    candidatePaths[2]
                ) returns (uint[] memory amounts) {
                    output3 = amounts[amounts.length - 1];
                } catch {
                    continue;
                }
                
                uint totalSplitOutput = output1 + output2 + output3;
                
                if (totalSplitOutput > bestThreeRouterOutput) {
                    bestThreeRouterOutput = totalSplitOutput;
                    bestThreeRouterSplits[0] = threeWaySplits[s][0];
                    bestThreeRouterSplits[1] = threeWaySplits[s][1];
                }
            }
        }
        
        // Strategy 4: Four-router split (with fixed ratio 40/30/20/10)
        uint bestFourRouterOutput = 0;
        
        if (candidateCount >= 4) {
            uint amount1 = (amountIn * 4000) / 10000;
            uint amount2 = (amountIn * 3000) / 10000;
            uint amount3 = (amountIn * 2000) / 10000;
            uint amount4 = amountIn - amount1 - amount2 - amount3;
            
            uint output1 = 0;
            uint output2 = 0;
            uint output3 = 0;
            uint output4 = 0;
            
            try IUniswapV2Router02(candidateRouters[0]).getAmountsOut(
                amount1, 
                candidatePaths[0]
            ) returns (uint[] memory amounts) {
                output1 = amounts[amounts.length - 1];
            } catch {
                // If this fails, output1 remains 0
            }
            
            try IUniswapV2Router02(candidateRouters[1]).getAmountsOut(
                amount2, 
                candidatePaths[1]
            ) returns (uint[] memory amounts) {
                output2 = amounts[amounts.length - 1];
            } catch {
                // If this fails, output2 remains 0
            }
            
            try IUniswapV2Router02(candidateRouters[2]).getAmountsOut(
                amount3, 
                candidatePaths[2]
            ) returns (uint[] memory amounts) {
                output3 = amounts[amounts.length - 1];
            } catch {
                // If this fails, output3 remains 0
            }
            
            try IUniswapV2Router02(candidateRouters[3]).getAmountsOut(
                amount4, 
                candidatePaths[3]
            ) returns (uint[] memory amounts) {
                output4 = amounts[amounts.length - 1];
            } catch {
                // If this fails, output4 remains 0
            }
            
            bestFourRouterOutput = output1 + output2 + output3 + output4;
        }
        
        // Calculate price impact for each strategy for better decision making
        uint priceImpactSingle = 0;
        uint priceImpactTwo = 0;
        uint priceImpactThree = 0;
        uint priceImpactFour = 0;
        
        if (singleRouterOutput > 0) {
            priceImpactSingle = calculatePriceImpact(amountIn, singleRouterOutput, inputToken, outputToken);
        }
        
        if (bestTwoRouterOutput > 0) {
            priceImpactTwo = calculatePriceImpact(amountIn, bestTwoRouterOutput, inputToken, outputToken);
        }
        
        if (bestThreeRouterOutput > 0) {
            priceImpactThree = calculatePriceImpact(amountIn, bestThreeRouterOutput, inputToken, outputToken);
        }
        
        if (bestFourRouterOutput > 0) {
            priceImpactFour = calculatePriceImpact(amountIn, bestFourRouterOutput, inputToken, outputToken);
        }
        
        // Apply small gas cost adjustments to multi-router strategies
        uint adjustedSingleOutput = singleRouterOutput;
        uint adjustedTwoOutput = bestTwoRouterOutput > 0 ? (bestTwoRouterOutput * 9995) / 10000 : 0; // 0.05% gas penalty
        uint adjustedThreeOutput = bestThreeRouterOutput > 0 ? (bestThreeRouterOutput * 9990) / 10000 : 0; // 0.1% gas penalty
        uint adjustedFourOutput = bestFourRouterOutput > 0 ? (bestFourRouterOutput * 9985) / 10000 : 0; // 0.15% gas penalty
        
        // Choose the best strategy based on adjusted outputs
        if (adjustedSingleOutput >= adjustedTwoOutput && adjustedSingleOutput >= adjustedThreeOutput && adjustedSingleOutput >= adjustedFourOutput) {
            // Single router is best
            bestSplits[0] = Split({
                router: candidateRouters[0],
                percentage: 10000, // 100%
                path: candidatePaths[0]
            });
            splitCount = 1;
            totalOutput = singleRouterOutput;
        }
        else if (adjustedTwoOutput >= adjustedSingleOutput && adjustedTwoOutput >= adjustedThreeOutput && adjustedTwoOutput >= adjustedFourOutput) {
            // Two router split is best
            bestSplits[0] = Split({
                router: candidateRouters[0],
                percentage: bestTwoRouterSplit,
                path: candidatePaths[0]
            });
            
            bestSplits[1] = Split({
                router: candidateRouters[1],
                percentage: 10000 - bestTwoRouterSplit,
                path: candidatePaths[1]
            });
            
            splitCount = 2;
            totalOutput = bestTwoRouterOutput;
        }
        else if (adjustedThreeOutput >= adjustedSingleOutput && adjustedThreeOutput >= adjustedTwoOutput && adjustedThreeOutput >= adjustedFourOutput) {
            // Three router split is best
            bestSplits[0] = Split({
                router: candidateRouters[0],
                percentage: bestThreeRouterSplits[0],
                path: candidatePaths[0]
            });
            
            bestSplits[1] = Split({
                router: candidateRouters[1],
                percentage: bestThreeRouterSplits[1],
                path: candidatePaths[1]
            });
            
            bestSplits[2] = Split({
                router: candidateRouters[2],
                percentage: 10000 - bestThreeRouterSplits[0] - bestThreeRouterSplits[1],
                path: candidatePaths[2]
            });
            
            splitCount = 3;
            totalOutput = bestThreeRouterOutput;
        }
        else {
            // Four router split is best
            bestSplits[0] = Split({
                router: candidateRouters[0],
                percentage: 4000, // 40%
                path: candidatePaths[0]
            });
            
            bestSplits[1] = Split({
                router: candidateRouters[1],
                percentage: 3000, // 30%
                path: candidatePaths[1]
            });
            
            bestSplits[2] = Split({
                router: candidateRouters[2],
                percentage: 2000, // 20%
                path: candidatePaths[2]
            });
            
            bestSplits[3] = Split({
                router: candidateRouters[3],
                percentage: 1000, // 10%
                path: candidatePaths[3]
            });
            
            splitCount = 4;
            totalOutput = bestFourRouterOutput;
        }
        
        // Calculate route hash for future optimization (removed state modification)
        bytes32 routeHash = keccak256(abi.encode(inputToken, outputToken, amountIn / 1e15)); // Round to nearest 0.001 token
        // State modification removed to keep function view
        
        // Resize bestSplits to actual count
        assembly {
            mstore(bestSplits, splitCount)
        }
        
        return (totalOutput, bestSplits);
    }

    // Get a list of common stablecoins for routing
    function getCommonStablecoins() external view returns (address[] memory) {
        // Filter bridge tokens to get only stablecoins (high weight tokens)
        uint stablecoinCount = 0;
        
        // First count the stablecoins
        for (uint i = 0; i < bridgeTokens.length; i++) {
            if (bridgeTokenWeights[bridgeTokens[i]] >= 500) { // High weight = likely stablecoin
                stablecoinCount++;
            }
        }
        
        // Then create the array
        address[] memory stablecoins = new address[](stablecoinCount);
        uint index = 0;
        
        for (uint i = 0; i < bridgeTokens.length && index < stablecoinCount; i++) {
            if (bridgeTokenWeights[bridgeTokens[i]] >= 500) {
                stablecoins[index] = bridgeTokens[i];
                index++;
            }
        }
        
        return stablecoins;
    }

    // Recursively try multi-hop routes
    function findMultiHopRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint currentHop,
        uint maxHops,
        address[] memory previousPath
    ) internal view returns (TradeRoute memory route, uint expectedOut) {
        // Base case: we've reached max hops or we're already checking a direct route
        if (currentHop >= maxHops || inputToken == outputToken) {
            TradeRoute memory emptyRoute;
            return (emptyRoute, 0);
        }
        
        // Try a direct route first
        try this.findBestSplitForHop(
            amountIn,
            inputToken,
            outputToken,
            previousPath
        ) returns (uint directOutput, Split[] memory directSplits) {
            if (directOutput > 0 && directSplits.length > 0) {
                // Create and populate route more efficiently
                TradeRoute memory directRoute = TradeRoute({
                    inputToken: inputToken,
                    outputToken: outputToken,
                    hops: 1,
                    splitRoutes: new Split[][](1)
                });
                directRoute.splitRoutes[0] = directSplits;
                
                return (directRoute, directOutput);
            }
        } catch {
            // Continue if direct route fails
        }
        
        // Try routes through bridge tokens
        TradeRoute memory bestMultiHopRoute;
        uint bestMultiHopOutput = 0;
        
        // Get top bridge tokens by weight
        uint maxBridgesToTry = 3; // Limit to top 3 for gas efficiency
        if (maxBridgesToTry > bridgeTokens.length) maxBridgesToTry = bridgeTokens.length;
        
        for (uint i = 0; i < maxBridgesToTry; i++) {
            address bridgeToken = bridgeTokens[i];
            
            // Skip if bridge token is in previous path to avoid circular routes
            bool tokenInPreviousPath = false;
            for (uint j = 0; j < previousPath.length; j++) {
                if (previousPath[j] == bridgeToken) {
                    tokenInPreviousPath = true;
                    break;
                }
            }
            
            if (tokenInPreviousPath || bridgeToken == inputToken || bridgeToken == outputToken) {
                continue;
            }
            
            // First hop: input to bridge
            try this.findBestSplitForHop(
                amountIn,
                inputToken,
                bridgeToken,
                previousPath
            ) returns (uint firstHopOutput, Split[] memory firstHopSplits) {
                if (firstHopOutput > 0 && firstHopSplits.length > 0) {
                    // Add bridge to previous path for recursive call
                    address[] memory newPreviousPath = new address[](previousPath.length + 1);
                    for (uint j = 0; j < previousPath.length; j++) {
                        newPreviousPath[j] = previousPath[j];
                    }
                    newPreviousPath[previousPath.length] = bridgeToken;
                    
                    // Second hop: bridge to output (recursive call)
                    (TradeRoute memory subRoute, uint secondHopOutput) = findMultiHopRoute(
                        firstHopOutput,
                        bridgeToken,
                        outputToken,
                        currentHop + 1,
                        maxHops,
                        newPreviousPath
                    );
                    
                    // If no valid sub-route, try direct for second hop
                    if (secondHopOutput == 0) {
                        try this.findBestSplitForHop(
                            firstHopOutput,
                            bridgeToken,
                            outputToken,
                            newPreviousPath
                        ) returns (uint directSecondOutput, Split[] memory directSecondSplits) {
                            if (directSecondOutput > 0 && directSecondSplits.length > 0) {
                                // Create a complete route
                                // Create route data structure efficiently to avoid stack depth issues
                                TradeRoute memory completeRoute = TradeRoute({
                                    inputToken: inputToken,
                                    outputToken: outputToken,
                                    hops: 2,
                                    splitRoutes: new Split[][](2)
                                });
                                completeRoute.splitRoutes[0] = firstHopSplits;
                                completeRoute.splitRoutes[1] = directSecondSplits;
                                
                                if (directSecondOutput > bestMultiHopOutput) {
                                    bestMultiHopRoute = completeRoute;
                                    bestMultiHopOutput = directSecondOutput;
                                }
                            }
                        } catch {
                            // Continue if second hop direct route fails
                        }
                    } 
                    // If valid sub-route exists, combine routes
                    else if (secondHopOutput > bestMultiHopOutput) {
                        // Create a complete route by combining first hop with sub-route
                        // Using struct initialization to reduce stack depth
                        TradeRoute memory completeRoute = TradeRoute({
                            inputToken: inputToken,
                            outputToken: outputToken,
                            hops: 1 + subRoute.hops,
                            splitRoutes: new Split[][](1 + subRoute.hops)
                        });
                        
                        // Split routes array already allocated in constructor
                        
                        // Add first hop
                        completeRoute.splitRoutes[0] = firstHopSplits;
                        
                        // Add remaining hops from sub-route
                        for (uint j = 0; j < subRoute.hops; j++) {
                            completeRoute.splitRoutes[j+1] = subRoute.splitRoutes[j];
                        }
                        
                        bestMultiHopRoute = completeRoute;
                        bestMultiHopOutput = secondHopOutput;
                    }
                }
            } catch {
                // Continue if first hop fails
            }
        }
        
        return (bestMultiHopRoute, bestMultiHopOutput);
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
        
        // Try direct route first (single hop)
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
            }
        } catch {
            // Continue if direct route fails
        }

        // For each bridge token, try multi-hop routes
        address[] memory emptyPath = new address[](0);
        
        // Try iterative approach with increasing hop count for better performance
        for (uint maxHops = 2; maxHops <= MAX_HOPS; maxHops++) {
            (TradeRoute memory multiHopRoute, uint multiHopOutput) = findMultiHopRoute(
                amountIn,
                inputToken,
                outputToken,
                1,
                maxHops,
                emptyPath
            );
            
            // Update best route if better
            if (multiHopOutput > expectedOut) {
                bestRoute = multiHopRoute;
                expectedOut = multiHopOutput;
            }
            
            // If we found a good route, stop iterating
            if (expectedOut > 0 && expectedOut > amountIn / 2) {
                break;
            }
        }
        
        // Fallback to WETH or known bridge tokens if no route found yet
        if (expectedOut == 0) {
            // Try through WETH explicitly if neither token is WETH
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
                            if (finalOutput > 0 && wethToOutRouter != address(0)) {
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
            
            // Try through stablecoins with improved handling
            try this.getCommonStablecoins() returns (address[] memory stablecoins) {
                for (uint i = 0; i < stablecoins.length; i++) {
                    address stablecoin = stablecoins[i];
                    if (stablecoin == address(0) || stablecoin == inputToken || stablecoin == outputToken) {
                        continue;
                    }
                    
                    // Try one router at a time for each stablecoin path
                    for (uint j = 0; j < routers.length; j++) {
                        address router = routers[j];
                        
                        // Try first hop
                        address[] memory firstPath = getPath(inputToken, stablecoin);
                        uint firstHopOutput = 0;
                        
                        try IUniswapV2Router02(router).getAmountsOut(amountIn, firstPath) returns (uint[] memory amounts) {
                            firstHopOutput = amounts[amounts.length - 1];
                            
                            if (firstHopOutput > 0) {
                                // Try second hop with the same router
                                address[] memory secondPath = getPath(stablecoin, outputToken);
                                
                                try IUniswapV2Router02(router).getAmountsOut(firstHopOutput, secondPath) returns (uint[] memory secondAmounts) {
                                    uint secondHopOutput = secondAmounts[secondAmounts.length - 1];
                                    
                                    if (secondHopOutput > expectedOut) {
                                        TradeRoute memory stablecoinRoute;
                                        stablecoinRoute.inputToken = inputToken;
                                        stablecoinRoute.outputToken = outputToken;
                                        stablecoinRoute.hops = 2;
                                        stablecoinRoute.splitRoutes = new Split[][](2);
                                        
                                        // First hop
                                        stablecoinRoute.splitRoutes[0] = new Split[](1);
                                        stablecoinRoute.splitRoutes[0][0] = Split({
                                            router: router,
                                            percentage: 10000, // 100%
                                            path: firstPath
                                        });
                                        
                                        // Second hop
                                        stablecoinRoute.splitRoutes[1] = new Split[](1);
                                        stablecoinRoute.splitRoutes[1][0] = Split({
                                            router: router,
                                            percentage: 10000, // 100%
                                            path: secondPath
                                        });
                                        
                                        bestRoute = stablecoinRoute;
                                        expectedOut = secondHopOutput;
                                    }
                                } catch {
                                    // Try a different router for the second hop
                                    for (uint k = 0; k < routers.length; k++) {
                                        if (k == j) continue; // Skip the same router
                                        
                                        address secondRouter = routers[k];
                                        
                                        try IUniswapV2Router02(secondRouter).getAmountsOut(firstHopOutput, secondPath) returns (uint[] memory crossAmounts) {
                                            uint crossHopOutput = crossAmounts[crossAmounts.length - 1];
                                            
                                            if (crossHopOutput > expectedOut) {
                                                // Create the route data struct more efficiently to avoid stack too deep errors
                                                TradeRoute memory crossRoute = TradeRoute({
                                                    inputToken: inputToken,
                                                    outputToken: outputToken,
                                                    hops: 2,
                                                    splitRoutes: new Split[][](2)
                                                });
                                                
                                                // First hop
                                                crossRoute.splitRoutes[0] = new Split[](1);
                                                crossRoute.splitRoutes[0][0] = Split({
                                                    router: router,
                                                    percentage: 10000, // 100%
                                                    path: firstPath
                                                });
                                                
                                                // Second hop
                                                crossRoute.splitRoutes[1] = new Split[](1);
                                                crossRoute.splitRoutes[1][0] = Split({
                                                    router: secondRouter,
                                                    percentage: 10000, // 100%
                                                    path: secondPath
                                                });
                                                
                                                bestRoute = crossRoute;
                                                expectedOut = crossHopOutput;
                                            }
                                        } catch {
                                            // Continue
                                        }
                                    }
                                }
                            }
                        } catch {
                            // Continue
                        }
                    }
                }
            } catch {
                // Continue if stablecoin approach fails
            }
        }
        
        return (bestRoute, expectedOut);
    }

    // Helper to estimate execution gas cost of a route
    function estimateRouteGas(TradeRoute memory route) internal pure returns (uint) {
        uint baseGas = 21000; // Base transaction cost
        uint routerCallGas = 150000; // Approx gas for a router call
        uint gasEstimate = baseGas;
        
        // Add gas for each hop
        for (uint i = 0; i < route.hops; i++) {
            // Gas for each split in this hop
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                // Longer paths use more gas
                uint pathLength = route.splitRoutes[i][j].path.length;
                gasEstimate += routerCallGas + (pathLength * 20000);
            }
        }
        
        return gasEstimate;
    }

    // Execute a swap using the optimized route
    function executeSwap(
        uint amountIn,
        uint minAmountOut,
        address inputToken,
        address outputToken,
        uint deadline
    ) external payable nonReentrant returns (uint amountOut) {
        require(deadline >= block.timestamp, "Deadline expired");
        
        // Find the best route
        (TradeRoute memory route, uint expectedOutput) = this.findBestRoute(amountIn, inputToken, outputToken);
        require(expectedOutput > 0, "No route found");
        require(expectedOutput >= minAmountOut, "Insufficient output amount");
        
        // Estimate gas cost to abort if too expensive
        uint gasEstimate = estimateRouteGas(route);
        require(gasleft() >= gasEstimate, "Insufficient gas for execution");
        
        // Handle ETH / WETH if needed
        bool inputIsETH = inputToken == WETH && msg.value > 0;
        bool outputIsETH = outputToken == WETH;
        uint actualAmountIn = inputIsETH ? msg.value : amountIn;
        
        // Transfer tokens from user for non-ETH input
        if (!inputIsETH) {
            require(msg.value == 0, "ETH sent with token swap");
            require(IERC20(inputToken).transferFrom(msg.sender, address(this), amountIn), "Transfer failed");
        }
        
        // Keep track of accumulated output
        amountOut = 0;
        
        // Execute each hop in the route
        for (uint i = 0; i < route.hops; i++) {
            address currentInput = i == 0 ? inputToken : route.splitRoutes[i-1][0].path[route.splitRoutes[i-1][0].path.length - 1];
            
            // For the first hop, we use the user's input amount
            uint currentAmountIn = i == 0 ? actualAmountIn : amountOut;
            amountOut = 0; // Reset output accumulator for this hop
            
            // Execute each split in this hop
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                Split memory split = route.splitRoutes[i][j];
                
                // Calculate the portion of input for this split
                uint splitAmountIn = (currentAmountIn * split.percentage) / 10000;
                if (splitAmountIn == 0) continue;
                
                // Approve router to spend tokens
                if (currentInput != WETH || !inputIsETH || i > 0) {
                    IERC20(currentInput).approve(split.router, splitAmountIn);
                }
                
                // Execute the swap based on the token types
                uint[] memory amounts;
                
                if (i == 0 && inputIsETH) {
                    // First hop with ETH input
                    amounts = IUniswapV2Router02(split.router).swapExactETHForTokens{value: splitAmountIn}(
                        0, // No min output here, we'll check the final amount
                        split.path,
                        address(this),
                        deadline
                    );
                } 
                else if (i == route.hops - 1 && outputIsETH) {
                    // Last hop with ETH output
                    amounts = IUniswapV2Router02(split.router).swapExactTokensForETH(
                        splitAmountIn,
                        0, // No min output here, we'll check the final amount
                        split.path,
                        address(this),
                        deadline
                    );
                } 
                else {
                    // Regular token to token swap
                    amounts = IUniswapV2Router02(split.router).swapExactTokensForTokens(
                        splitAmountIn,
                        0, // No min output here, we'll check the final amount
                        split.path,
                        address(this),
                        deadline
                    );
                }
                
                // Add the output to the accumulated amount
                uint splitOutput = amounts[amounts.length - 1];
                amountOut += splitOutput;
                
                // Update path performance data
                updatePathPerformance(
                    split.path, 
                    true, 
                    (splitOutput * 10000) / splitAmountIn // Performance metric: output/input ratio in BPS
                );
            }
            
            // If this isn't the last hop, make sure we have output for the next hop
            if (i < route.hops - 1) {
                require(amountOut > 0, "Intermediate hop returned zero");
            }
        }
        
        require(amountOut >= minAmountOut, "Output less than expected");
        
        // Calculate fee (0.3%)
        uint fee = amountOut * 3 / 1000;
        uint amountAfterFee = amountOut - fee;
        
        // Transfer output token to user
        if (outputIsETH) {
            // Accumulate ETH fee
            feeAccumulatedETH += fee;
            // Send ETH to user
            (bool success, ) = msg.sender.call{value: amountAfterFee}("");
            require(success, "ETH transfer failed");
        } else {
            // Accumulate token fee
            feeAccumulatedTokens[outputToken] += fee;
            // Send tokens to user
            require(IERC20(outputToken).transfer(msg.sender, amountAfterFee), "Token transfer failed");
        }
        
        emit SwapExecuted(msg.sender, actualAmountIn, amountAfterFee);
        return amountAfterFee;
    }

    // Withdraw accumulated fees
    function withdrawFees(address[] calldata tokens) external onlyOwner {
        // Withdraw ETH fees
        if (feeAccumulatedETH > 0) {
            uint ethAmount = feeAccumulatedETH;
            feeAccumulatedETH = 0;
            (bool success, ) = owner.call{value: ethAmount}("");
            require(success, "ETH transfer failed");
            emit FeesWithdrawn(owner, ethAmount);
        }
        
        // Withdraw token fees
        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint amount = feeAccumulatedTokens[token];
            if (amount > 0) {
                feeAccumulatedTokens[token] = 0;
                require(IERC20(token).transfer(owner, amount), "Token transfer failed");
                emit TokenFeesWithdrawn(owner, token, amount);
            }
        }
    }

    // Rescue tokens that are stuck in the contract
    function rescueTokens(address token, uint amount) external onlyOwner {
        if (token == address(0)) {
            // Rescue ETH
            (bool success, ) = owner.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Rescue ERC20 tokens
            require(IERC20(token).transfer(owner, amount), "Token transfer failed");
        }
    }

    // Required to receive ETH
    receive() external payable {}
}
