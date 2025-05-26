
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
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);
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
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

contract MonBridgeDex {
    address public owner;
    address[] public routers;
    address[] public intermediateTokens;
    address[] public stablecoins;
    address[] public popularTokens;
    
    uint public constant MAX_ROUTERS = 20;
    uint public constant MAX_HOPS = 8;
    uint public constant MAX_SPLITS_PER_HOP = 10;
    uint public constant MAX_INTERMEDIATE_TOKENS = 50;

    // Optimized limits for gas efficiency
    uint public constant MAX_ROUTE_CANDIDATES = 100; // Reduced from 1000
    uint public constant MAX_ARBITRAGE_OPPORTUNITIES = 20; // Reduced from 50
    uint public constant MAX_PATH_COMBINATIONS = 15; // Reduced for efficiency

    // Enhanced slippage management
    uint public defaultSlippageBps = 30;
    uint public minSlippageBps = 5;
    uint public maxSlippageBps = 300;
    uint public arbitrageSlippageBps = 10;

    uint public constant SPLIT_THRESHOLD_BPS = 25;
    uint public constant ARBITRAGE_MIN_PROFIT_BPS = 50;
    uint public constant FEE_DIVISOR = 2000;
    uint public feeAccumulatedETH;
    
    mapping(address => uint) public feeAccumulatedTokens;
    address public WETH;

    mapping(address => bool) public whitelistedTokens;
    mapping(address => uint) public tokenLiquidityWeight;
    mapping(address => bool) public isStablecoin;
    mapping(address => bool) public isPopularToken;
    
    // Dynamic token discovery
    mapping(address => mapping(address => bool)) public validPairs;
    mapping(address => address[]) public tokenConnections;
    mapping(address => uint) public tokenVolume24h;
    mapping(address => uint) public lastVolumeUpdate;
    
    // Arbitrage tracking
    mapping(bytes32 => uint) public lastArbitrageTimestamp;
    uint public constant ARBITRAGE_COOLDOWN = 30;
    
    // Dynamic path caching
    mapping(bytes32 => address[]) public cachedPaths;
    mapping(bytes32 => uint) public pathCacheTimestamp;
    uint public constant PATH_CACHE_DURATION = 300; // 5 minutes

    struct Split {
        address router;    
        uint percentage;
        address[] path;
        uint expectedOutput;
        uint liquidityScore;
        uint gasEstimate;
    }

    struct TradeRoute {
        address inputToken;
        address outputToken;
        uint hops;            
        Split[][] splitRoutes;
        bool isArbitrage;
        uint arbitrageProfitBps;
        uint totalGasEstimate;
        uint routeScore;
    }

    struct RouteCandidate {
        TradeRoute route;
        uint expectedOutput;
        uint hopCount;
        uint complexity;
        uint gasEstimate;
        uint profitScore;
        uint liquidityScore;
        uint diversificationScore;
    }

    struct ArbitrageOpportunity {
        address[] path;
        address[] routers;
        uint expectedProfit;
        uint profitBps;
        bool isTriangular;
        uint confidence;
    }

    struct RouterOutput {
        address router;
        uint output;
        uint index;
        uint liquidityScore;
        uint gasEstimate;
        uint reliabilityScore;
    }

    struct PriceInfo {
        address router;
        uint price;
        uint liquidity;
        uint slippage;
        uint volume;
        uint confidence;
    }

    struct TokenMetrics {
        uint liquidity;
        uint volume24h;
        uint connections;
        uint reliability;
        bool isVerified;
    }

    struct PathDiscovery {
        address token;
        uint depth;
        uint[] scores;
        address[] intermediates;
    }

    // Enhanced reentrancy guard
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
    event TokenAdded(address token, string tokenType);
    event TokenRemoved(address token);
    event SwapExecuted(address indexed user, uint amountIn, uint amountOut);
    event ArbitrageExecuted(address indexed user, uint profit, uint profitBps);
    event PathDiscovered(address tokenA, address tokenB, address[] path);
    event LiquidityUpdated(address indexed token, uint newWeight);

    constructor(address _weth) {
        owner = msg.sender;
        WETH = _weth;
        whitelistedTokens[_weth] = true;
        tokenLiquidityWeight[_weth] = 1000;
        
        // Add WETH as first intermediate token
        intermediateTokens.push(_weth);
    }

    // **DYNAMIC TOKEN MANAGEMENT**
    function addIntermediateTokens(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Invalid token address");
            require(intermediateTokens.length < MAX_INTERMEDIATE_TOKENS, "Max tokens reached");
            
            bool exists = false;
            for (uint j = 0; j < intermediateTokens.length; j++) {
                if (intermediateTokens[j] == tokens[i]) {
                    exists = true;
                    break;
                }
            }
            
            if (!exists) {
                intermediateTokens.push(tokens[i]);
                whitelistedTokens[tokens[i]] = true;
                emit TokenAdded(tokens[i], "intermediate");
            }
        }
    }

    function addStablecoins(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Invalid token address");
            
            bool exists = false;
            for (uint j = 0; j < stablecoins.length; j++) {
                if (stablecoins[j] == tokens[i]) {
                    exists = true;
                    break;
                }
            }
            
            if (!exists) {
                stablecoins.push(tokens[i]);
                isStablecoin[tokens[i]] = true;
                whitelistedTokens[tokens[i]] = true;
                tokenLiquidityWeight[tokens[i]] = 800; // High weight for stables
                emit TokenAdded(tokens[i], "stablecoin");
            }
        }
    }

    function addPopularTokens(address[] calldata tokens) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Invalid token address");
            
            bool exists = false;
            for (uint j = 0; j < popularTokens.length; j++) {
                if (popularTokens[j] == tokens[i]) {
                    exists = true;
                    break;
                }
            }
            
            if (!exists) {
                popularTokens.push(tokens[i]);
                isPopularToken[tokens[i]] = true;
                whitelistedTokens[tokens[i]] = true;
                tokenLiquidityWeight[tokens[i]] = 600;
                emit TokenAdded(tokens[i], "popular");
            }
        }
    }

    function removeToken(address token) external onlyOwner {
        // Remove from intermediate tokens
        for (uint i = 0; i < intermediateTokens.length; i++) {
            if (intermediateTokens[i] == token) {
                intermediateTokens[i] = intermediateTokens[intermediateTokens.length - 1];
                intermediateTokens.pop();
                break;
            }
        }
        
        // Remove from stablecoins
        for (uint i = 0; i < stablecoins.length; i++) {
            if (stablecoins[i] == token) {
                stablecoins[i] = stablecoins[stablecoins.length - 1];
                stablecoins.pop();
                break;
            }
        }
        
        // Remove from popular tokens
        for (uint i = 0; i < popularTokens.length; i++) {
            if (popularTokens[i] == token) {
                popularTokens[i] = popularTokens[popularTokens.length - 1];
                popularTokens.pop();
                break;
            }
        }
        
        whitelistedTokens[token] = false;
        isStablecoin[token] = false;
        isPopularToken[token] = false;
        emit TokenRemoved(token);
    }

    // **DYNAMIC ROUTER MANAGEMENT**
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

    // **OPTIMIZED PATH DISCOVERY**
    function discoverOptimalPath(
        address tokenIn,
        address tokenOut,
        uint amountIn
    ) public view returns (address[] memory bestPath, uint bestOutput) {
        bytes32 pathKey = keccak256(abi.encodePacked(tokenIn, tokenOut, amountIn / 1e15));
        
        // Check cache first
        if (block.timestamp - pathCacheTimestamp[pathKey] < PATH_CACHE_DURATION) {
            address[] memory cached = cachedPaths[pathKey];
            if (cached.length > 0) {
                uint output = calculatePathOutput(amountIn, cached);
                if (output > 0) {
                    return (cached, output);
                }
            }
        }

        bestOutput = 0;
        
        // Direct path
        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;
        uint directOutput = calculatePathOutput(amountIn, directPath);
        
        if (directOutput > bestOutput) {
            bestOutput = directOutput;
            bestPath = directPath;
        }

        // Limited intermediate paths for gas efficiency
        address[] memory limitedIntermediates = getLimitedIntermediateTokens();
        
        // Single intermediate paths (limited to first 10 for gas efficiency)
        uint maxSingleHop = limitedIntermediates.length > 10 ? 10 : limitedIntermediates.length;
        for (uint i = 0; i < maxSingleHop; i++) {
            address intermediate = limitedIntermediates[i];
            if (intermediate == tokenIn || intermediate == tokenOut) continue;

            address[] memory singleHopPath = new address[](3);
            singleHopPath[0] = tokenIn;
            singleHopPath[1] = intermediate;
            singleHopPath[2] = tokenOut;
            
            uint singleHopOutput = calculatePathOutput(amountIn, singleHopPath);
            if (singleHopOutput > bestOutput) {
                bestOutput = singleHopOutput;
                bestPath = singleHopPath;
            }
        }

        // Limited two intermediate paths (only for high priority tokens)
        uint maxDoubleHop = limitedIntermediates.length > 5 ? 5 : limitedIntermediates.length;
        for (uint i = 0; i < maxDoubleHop; i++) {
            address intermediate1 = limitedIntermediates[i];
            if (intermediate1 == tokenIn || intermediate1 == tokenOut) continue;

            for (uint j = i + 1; j < maxDoubleHop; j++) {
                address intermediate2 = limitedIntermediates[j];
                if (intermediate2 == tokenIn || intermediate2 == tokenOut || intermediate2 == intermediate1) continue;

                address[] memory doubleHopPath = new address[](4);
                doubleHopPath[0] = tokenIn;
                doubleHopPath[1] = intermediate1;
                doubleHopPath[2] = intermediate2;
                doubleHopPath[3] = tokenOut;
                
                uint doubleHopOutput = calculatePathOutput(amountIn, doubleHopPath);
                if (doubleHopOutput > bestOutput) {
                    bestOutput = doubleHopOutput;
                    bestPath = doubleHopPath;
                }
            }
        }

        return (bestPath, bestOutput);
    }

    // **GAS OPTIMIZED HELPER - RETURNS PRIORITIZED SUBSET**
    function getLimitedIntermediateTokens() internal view returns (address[] memory) {
        // Prioritize WETH, stablecoins, and popular tokens for better gas efficiency
        address[] memory limited = new address[](15); // Fixed small size
        uint idx = 0;
        
        // Add WETH first (highest priority)
        if (idx < limited.length) {
            limited[idx++] = WETH;
        }
        
        // Add stablecoins (high priority)
        for (uint i = 0; i < stablecoins.length && idx < limited.length; i++) {
            if (stablecoins[i] != WETH) {
                limited[idx++] = stablecoins[i];
            }
        }
        
        // Add popular tokens
        for (uint i = 0; i < popularTokens.length && idx < limited.length; i++) {
            bool isDuplicate = false;
            for (uint j = 0; j < idx; j++) {
                if (popularTokens[i] == limited[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                limited[idx++] = popularTokens[i];
            }
        }
        
        // Add remaining intermediate tokens if space
        for (uint i = 0; i < intermediateTokens.length && idx < limited.length; i++) {
            bool isDuplicate = false;
            for (uint j = 0; j < idx; j++) {
                if (intermediateTokens[i] == limited[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                limited[idx++] = intermediateTokens[i];
            }
        }
        
        // Create result array with only filled elements
        address[] memory result = new address[](idx);
        for (uint i = 0; i < idx; i++) {
            result[i] = limited[i];
        }
        
        return result;
    }

    function calculatePathOutput(uint amountIn, address[] memory path) public view returns (uint finalOutput) {
        if (path.length < 2) return 0;
        
        uint bestTotalOutput = 0;
        
        // Test path on limited routers for gas efficiency (max 5)
        uint maxRouters = routers.length > 5 ? 5 : routers.length;
        for (uint r = 0; r < maxRouters; r++) {
            if (routers[r] == address(0)) continue;
            
            try IUniswapV2Router02(routers[r]).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                if (amounts.length > 0) {
                    uint output = amounts[amounts.length - 1];
                    if (output > bestTotalOutput) {
                        bestTotalOutput = output;
                    }
                }
            } catch {
                continue;
            }
        }
        
        return bestTotalOutput;
    }

    // **OPTIMIZED ROUTE FINDING WITH GAS LIMITS**
    function findBestRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (TradeRoute memory route, uint expectedOut) {
        require(amountIn > 0, "Amount must be greater than 0");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(inputToken != outputToken, "Input and output tokens must be different");
        require(routers.length > 0, "No routers configured");

        // Optimized arbitrage detection with limits
        ArbitrageOpportunity[] memory arbitrageOps = findLimitedArbitrageOpportunities(amountIn, inputToken, outputToken);
        
        // Limited route search
        RouteCandidate[] memory candidates = new RouteCandidate[](MAX_ROUTE_CANDIDATES);
        uint candidateCount = 0;

        // Add best arbitrage routes (limited)
        for (uint i = 0; i < arbitrageOps.length && candidateCount < 15; i++) {
            if (arbitrageOps[i].expectedProfit > 0 && arbitrageOps[i].confidence > 70) {
                RouteCandidate memory arbCandidate = convertArbitrageToRoute(amountIn, arbitrageOps[i]);
                if (arbCandidate.expectedOutput > 0) {
                    candidates[candidateCount] = arbCandidate;
                    candidateCount++;
                }
            }
        }

        // Direct routes (optimized)
        candidateCount = findOptimizedDirectRoutes(amountIn, inputToken, outputToken, candidates, candidateCount);

        // Limited multi-hop routes
        candidateCount = findLimitedMultiHopRoutes(amountIn, inputToken, outputToken, candidates, candidateCount);

        // Limited cross-router opportunities
        candidateCount = findLimitedCrossRouterArbitrage(amountIn, inputToken, outputToken, candidates, candidateCount);

        // Select optimal route
        return selectOptimalRoute(candidates, candidateCount);
    }

    // **OPTIMIZED ARBITRAGE DETECTION**
    function findLimitedArbitrageOpportunities(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (ArbitrageOpportunity[] memory opportunities) {
        opportunities = new ArbitrageOpportunity[](MAX_ARBITRAGE_OPPORTUNITIES);
        uint opCount = 0;

        // Limited direct arbitrage
        opCount = findLimitedDirectArbitrage(amountIn, inputToken, outputToken, opportunities, opCount);

        // Limited triangular arbitrage
        opCount = findLimitedTriangularArbitrage(amountIn, inputToken, outputToken, opportunities, opCount);

        return opportunities;
    }

    function findLimitedDirectArbitrage(
        uint amountIn,
        address inputToken,
        address outputToken,
        ArbitrageOpportunity[] memory opportunities,
        uint currentCount
    ) internal view returns (uint newCount) {
        newCount = currentCount;
        
        // Limit to top 3 routers for gas efficiency
        uint maxRouters = routers.length > 3 ? 3 : routers.length;
        PriceInfo[] memory prices = new PriceInfo[](maxRouters);
        uint validPrices = 0;

        for (uint i = 0; i < maxRouters && validPrices < maxRouters; i++) {
            if (routers[i] == address(0)) continue;
            
            (address[] memory bestPath, uint output) = discoverOptimalPath(inputToken, outputToken, amountIn);
            if (output > 0 && bestPath.length > 0) {
                uint liquidity = getLiquidityScore(inputToken, outputToken, routers[i]);
                prices[validPrices] = PriceInfo({
                    router: routers[i],
                    price: (output * 1e18) / amountIn,
                    liquidity: liquidity,
                    slippage: calculateRouterSlippage(amountIn, inputToken, outputToken, routers[i]),
                    volume: getTokenVolume(inputToken) + getTokenVolume(outputToken),
                    confidence: calculateConfidenceScore(liquidity, getTokenVolume(inputToken))
                });
                validPrices++;
            }
        }

        // Find arbitrage with limited combinations
        for (uint i = 0; i < validPrices && newCount < currentCount + 8; i++) {
            for (uint j = i + 1; j < validPrices && newCount < currentCount + 8; j++) {
                if (prices[i].price > prices[j].price && prices[i].confidence > 50 && prices[j].confidence > 50) {
                    uint profitBps = ((prices[i].price - prices[j].price) * 10000) / prices[j].price;
                    
                    if (profitBps > ARBITRAGE_MIN_PROFIT_BPS) {
                        (address[] memory path,) = discoverOptimalPath(inputToken, outputToken, amountIn);
                        
                        address[] memory arbRouters = new address[](2);
                        arbRouters[0] = prices[i].router;
                        arbRouters[1] = prices[j].router;
                        
                        uint expectedProfit = ((prices[i].price - prices[j].price) * amountIn) / 1e18;
                        uint confidence = (prices[i].confidence + prices[j].confidence) / 2;
                        
                        opportunities[newCount] = ArbitrageOpportunity({
                            path: path,
                            routers: arbRouters,
                            expectedProfit: expectedProfit,
                            profitBps: profitBps,
                            isTriangular: false,
                            confidence: confidence
                        });
                        newCount++;
                    }
                }
            }
        }

        return newCount;
    }

    function findLimitedTriangularArbitrage(
        uint amountIn,
        address inputToken,
        address outputToken,
        ArbitrageOpportunity[] memory opportunities,
        uint currentCount
    ) internal view returns (uint newCount) {
        newCount = currentCount;
        
        address[] memory limitedIntermediates = getLimitedIntermediateTokens();
        uint maxIntermediates = limitedIntermediates.length > 8 ? 8 : limitedIntermediates.length;
        
        for (uint i = 0; i < maxIntermediates && newCount < currentCount + 10; i++) {
            address intermediate = limitedIntermediates[i];
            if (intermediate == inputToken || intermediate == outputToken) continue;

            address[] memory triangularPath = new address[](4);
            triangularPath[0] = inputToken;
            triangularPath[1] = intermediate;
            triangularPath[2] = outputToken;
            triangularPath[3] = inputToken;

            uint finalAmount = calculateTriangularOutput(amountIn, triangularPath);
            
            if (finalAmount > amountIn) {
                uint profitBps = ((finalAmount - amountIn) * 10000) / amountIn;
                
                if (profitBps > ARBITRAGE_MIN_PROFIT_BPS) {
                    address[] memory bestRouters = findBestRoutersForPath(triangularPath);
                    uint confidence = calculateTriangularConfidence(triangularPath, bestRouters);
                    
                    if (confidence > 60) {
                        opportunities[newCount] = ArbitrageOpportunity({
                            path: triangularPath,
                            routers: bestRouters,
                            expectedProfit: finalAmount - amountIn,
                            profitBps: profitBps,
                            isTriangular: true,
                            confidence: confidence
                        });
                        newCount++;
                    }
                }
            }
        }

        return newCount;
    }

    // **OPTIMIZED ROUTE BUILDING**
    function findOptimizedDirectRoutes(
        uint amountIn,
        address inputToken,
        address outputToken,
        RouteCandidate[] memory candidates,
        uint currentCount
    ) internal view returns (uint newCount) {
        newCount = currentCount;

        (uint bestOutput, Split[] memory bestSplits) = findOptimalSplitForPair(
            amountIn, inputToken, outputToken
        );

        if (bestOutput > 0 && bestSplits.length > 0 && newCount < MAX_ROUTE_CANDIDATES) {
            TradeRoute memory directRoute;
            directRoute.inputToken = inputToken;
            directRoute.outputToken = outputToken;
            directRoute.hops = 1;
            directRoute.splitRoutes = new Split[][](1);
            directRoute.splitRoutes[0] = bestSplits;
            directRoute.isArbitrage = false;
            directRoute.totalGasEstimate = estimateGasForRoute(directRoute);
            directRoute.routeScore = calculateRouteScore(directRoute, bestOutput);

            candidates[newCount] = RouteCandidate({
                route: directRoute,
                expectedOutput: bestOutput,
                hopCount: 1,
                complexity: bestSplits.length,
                gasEstimate: directRoute.totalGasEstimate,
                profitScore: calculateProfitScore(bestOutput, 1, bestSplits.length, directRoute.totalGasEstimate),
                liquidityScore: calculateRouteLiquidityScore(directRoute),
                diversificationScore: bestSplits.length * 10
            });
            newCount++;
        }

        return newCount;
    }

    function findLimitedMultiHopRoutes(
        uint amountIn,
        address inputToken,
        address outputToken,
        RouteCandidate[] memory candidates,
        uint currentCount
    ) internal view returns (uint newCount) {
        newCount = currentCount;
        
        address[] memory limitedIntermediates = getLimitedIntermediateTokens();
        uint maxIntermediates = limitedIntermediates.length > 8 ? 8 : limitedIntermediates.length;

        // Limited 2-hop routes
        for (uint i = 0; i < maxIntermediates && newCount < MAX_ROUTE_CANDIDATES - 20; i++) {
            address intermediate = limitedIntermediates[i];
            if (intermediate == inputToken || intermediate == outputToken) continue;

            RouteCandidate memory candidate = buildOptimalTwoHopRoute(
                amountIn, inputToken, intermediate, outputToken
            );
            if (candidate.expectedOutput > 0) {
                candidates[newCount] = candidate;
                newCount++;
            }
        }

        // Very limited 3-hop routes (only top 3 intermediates)
        uint maxThreeHop = maxIntermediates > 3 ? 3 : maxIntermediates;
        for (uint i = 0; i < maxThreeHop && newCount < MAX_ROUTE_CANDIDATES - 5; i++) {
            address intermediate1 = limitedIntermediates[i];
            if (intermediate1 == inputToken || intermediate1 == outputToken) continue;

            for (uint j = i + 1; j < maxThreeHop && newCount < MAX_ROUTE_CANDIDATES - 5; j++) {
                address intermediate2 = limitedIntermediates[j];
                if (intermediate2 == inputToken || intermediate2 == outputToken || intermediate2 == intermediate1) continue;

                RouteCandidate memory candidate = buildOptimalThreeHopRoute(
                    amountIn, inputToken, intermediate1, intermediate2, outputToken
                );
                if (candidate.expectedOutput > 0 && candidate.liquidityScore > 60) {
                    candidates[newCount] = candidate;
                    newCount++;
                }
            }
        }

        return newCount;
    }

    function findLimitedCrossRouterArbitrage(
        uint amountIn,
        address inputToken,
        address outputToken,
        RouteCandidate[] memory candidates,
        uint currentCount
    ) internal view returns (uint newCount) {
        newCount = currentCount;

        address[] memory limitedIntermediates = getLimitedIntermediateTokens();
        uint maxIntermediates = limitedIntermediates.length > 5 ? 5 : limitedIntermediates.length;

        for (uint i = 0; i < maxIntermediates && newCount < MAX_ROUTE_CANDIDATES - 2; i++) {
            address intermediate = limitedIntermediates[i];
            if (intermediate == inputToken || intermediate == outputToken) continue;

            (address bestRouter1, uint bestOutput1) = findBestRouterForPair(amountIn, inputToken, intermediate);
            if (bestRouter1 == address(0)) continue;

            (address bestRouter2, uint bestOutput2) = findBestRouterForPair(bestOutput1, intermediate, outputToken);
            if (bestRouter2 == address(0)) continue;

            TradeRoute memory crossRoute;
            crossRoute.inputToken = inputToken;
            crossRoute.outputToken = outputToken;
            crossRoute.hops = 2;
            crossRoute.splitRoutes = new Split[][](2);
            
            (address[] memory path1,) = discoverOptimalPath(inputToken, intermediate, amountIn);
            (address[] memory path2,) = discoverOptimalPath(intermediate, outputToken, bestOutput1);
            
            crossRoute.splitRoutes[0] = new Split[](1);
            crossRoute.splitRoutes[0][0] = Split({
                router: bestRouter1,
                percentage: 10000,
                path: path1,
                expectedOutput: bestOutput1,
                liquidityScore: getLiquidityScore(inputToken, intermediate, bestRouter1),
                gasEstimate: 80000 + (path1.length - 2) * 60000
            });
            
            crossRoute.splitRoutes[1] = new Split[](1);
            crossRoute.splitRoutes[1][0] = Split({
                router: bestRouter2,
                percentage: 10000,
                path: path2,
                expectedOutput: bestOutput2,
                liquidityScore: getLiquidityScore(intermediate, outputToken, bestRouter2),
                gasEstimate: 80000 + (path2.length - 2) * 60000
            });

            crossRoute.isArbitrage = true;
            crossRoute.totalGasEstimate = estimateGasForRoute(crossRoute);
            crossRoute.routeScore = calculateRouteScore(crossRoute, bestOutput2);

            uint liquidityScore = calculateRouteLiquidityScore(crossRoute);
            
            if (liquidityScore > 55) {
                candidates[newCount] = RouteCandidate({
                    route: crossRoute,
                    expectedOutput: bestOutput2,
                    hopCount: 2,
                    complexity: 2,
                    gasEstimate: crossRoute.totalGasEstimate,
                    profitScore: calculateProfitScore(bestOutput2, 2, 2, crossRoute.totalGasEstimate),
                    liquidityScore: liquidityScore,
                    diversificationScore: 20
                });
                newCount++;
            }
        }

        return newCount;
    }

    // **OPTIMIZED SPLIT FINDING**
    function findOptimalSplitForPair(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) public view returns (uint bestOutput, Split[] memory bestSplits) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (0, new Split[](0));
        }

        // Limited router analysis for gas efficiency
        uint maxRouters = routers.length > 5 ? 5 : routers.length;
        RouterOutput[] memory routerOutputs = new RouterOutput[](maxRouters);
        uint validRouterCount = 0;

        for (uint i = 0; i < maxRouters; i++) {
            if (routers[i] == address(0)) continue;

            (address[] memory optimalPath, uint output) = discoverOptimalPath(tokenIn, tokenOut, amountIn);
            if (output > 0) {
                uint liquidityScore = getLiquidityScore(tokenIn, tokenOut, routers[i]);
                uint reliabilityScore = getRouterReliability(routers[i]);
                uint gasEstimate = 80000 + (optimalPath.length - 2) * 60000;
                
                routerOutputs[validRouterCount] = RouterOutput({
                    router: routers[i],
                    output: output,
                    index: i,
                    liquidityScore: liquidityScore,
                    gasEstimate: gasEstimate,
                    reliabilityScore: reliabilityScore
                });
                validRouterCount++;
            }
        }

        if (validRouterCount == 0) return (0, new Split[](0));

        // Sort by composite score
        for (uint i = 0; i < validRouterCount - 1; i++) {
            for (uint j = i + 1; j < validRouterCount; j++) {
                uint scoreI = calculateRouterCompositeScore(routerOutputs[i]);
                uint scoreJ = calculateRouterCompositeScore(routerOutputs[j]);
                
                if (scoreJ > scoreI) {
                    RouterOutput memory temp = routerOutputs[i];
                    routerOutputs[i] = routerOutputs[j];
                    routerOutputs[j] = temp;
                }
            }
        }

        // Start with single best router
        (address[] memory bestPath,) = discoverOptimalPath(tokenIn, tokenOut, amountIn);
        bestOutput = routerOutputs[0].output;
        bestSplits = new Split[](1);
        bestSplits[0] = Split({
            router: routerOutputs[0].router,
            percentage: 10000,
            path: bestPath,
            expectedOutput: routerOutputs[0].output,
            liquidityScore: routerOutputs[0].liquidityScore,
            gasEstimate: routerOutputs[0].gasEstimate
        });

        // Test limited combinations (max 3 routers to save gas)
        if (validRouterCount >= 2) {
            uint maxCombinations = validRouterCount < 3 ? validRouterCount : 3;

            for (uint combSize = 2; combSize <= maxCombinations; combSize++) {
                (uint combOutput, Split[] memory combSplits) = findOptimalCombination(
                    amountIn, tokenIn, tokenOut, routerOutputs, combSize, validRouterCount
                );

                if (combOutput > bestOutput) {
                    bestOutput = combOutput;
                    bestSplits = combSplits;
                }
            }
        }

        return (bestOutput, bestSplits);
    }

    function findOptimalCombination(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        RouterOutput[] memory routerOutputs,
        uint combSize,
        uint validRouterCount
    ) internal view returns (uint bestOutput, Split[] memory bestSplits) {
        bestOutput = 0;

        // Limited percentage distributions for gas efficiency
        uint[][] memory percentageDistributions = generateLimitedPercentages(combSize);

        // Test limited combinations
        uint maxTests = validRouterCount - combSize + 1;
        if (maxTests > 3) maxTests = 3; // Limit to 3 combinations for gas

        for (uint startIdx = 0; startIdx < maxTests; startIdx++) {
            RouterOutput[] memory testRouters = new RouterOutput[](combSize);
            for (uint i = 0; i < combSize; i++) {
                testRouters[i] = routerOutputs[startIdx + i];
            }

            // Test limited percentage distributions
            uint maxDistributions = percentageDistributions.length > 10 ? 10 : percentageDistributions.length;
            for (uint distIdx = 0; distIdx < maxDistributions; distIdx++) {
                uint[] memory percentages = percentageDistributions[distIdx];
                if (percentages.length != combSize) continue;

                uint totalOutput = calculateCombinationOutput(
                    amountIn, tokenIn, tokenOut, testRouters, percentages
                );

                if (totalOutput > bestOutput) {
                    bestOutput = totalOutput;
                    bestSplits = new Split[](combSize);
                    (address[] memory path,) = discoverOptimalPath(tokenIn, tokenOut, amountIn);

                    for (uint i = 0; i < combSize; i++) {
                        bestSplits[i] = Split({
                            router: testRouters[i].router,
                            percentage: percentages[i],
                            path: path,
                            expectedOutput: (totalOutput * percentages[i]) / 10000,
                            liquidityScore: testRouters[i].liquidityScore,
                            gasEstimate: testRouters[i].gasEstimate
                        });
                    }
                }
            }
        }

        return (bestOutput, bestSplits);
    }

    function generateLimitedPercentages(uint routerCount) internal pure returns (uint[][] memory) {
        if (routerCount == 1) {
            uint[][] memory result = new uint[][](1);
            result[0] = new uint[](1);
            result[0][0] = 10000;
            return result;
        }

        if (routerCount == 2) {
            uint[][] memory result = new uint[][](20); // Reduced from 100
            uint idx = 0;

            // Simplified 2-router splits (5% increments)
            for (uint pct1 = 500; pct1 <= 9500; pct1 += 500) {
                if (idx >= 20) break;
                result[idx] = new uint[](2);
                result[idx][0] = pct1;
                result[idx][1] = 10000 - pct1;
                idx++;
            }
            return result;
        }

        if (routerCount == 3) {
            uint[][] memory result = new uint[][](25); // Reduced from 150
            uint idx = 0;

            // Simplified 3-router combinations
            for (uint pct1 = 1000; pct1 <= 7000; pct1 += 1000) {
                for (uint pct2 = 1000; pct2 <= 8000 - pct1; pct2 += 1000) {
                    uint pct3 = 10000 - pct1 - pct2;
                    if (pct3 >= 1000 && idx < 25) {
                        result[idx] = new uint[](3);
                        result[idx][0] = pct1;
                        result[idx][1] = pct2;
                        result[idx][2] = pct3;
                        idx++;
                    }
                }
            }
            return result;
        }

        // For 4+ routers, use simple equal distribution
        uint[][] memory result = new uint[][](1);
        result[0] = new uint[](routerCount);
        uint baseShare = 10000 / routerCount;
        uint remainder = 10000 % routerCount;
        
        for (uint i = 0; i < routerCount; i++) {
            result[0][i] = baseShare;
        }
        result[0][0] += remainder;
        
        return result;
    }

    // **ALL REMAINING HELPER FUNCTIONS WITH OPTIMIZATIONS**
    function getAllIntermediateTokens() public view returns (address[] memory) {
        uint totalLength = intermediateTokens.length + stablecoins.length + popularTokens.length;
        address[] memory allTokens = new address[](totalLength);
        uint idx = 0;
        
        for (uint i = 0; i < intermediateTokens.length; i++) {
            allTokens[idx++] = intermediateTokens[i];
        }
        
        for (uint i = 0; i < stablecoins.length; i++) {
            bool isDuplicate = false;
            for (uint j = 0; j < intermediateTokens.length; j++) {
                if (stablecoins[i] == intermediateTokens[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                allTokens[idx++] = stablecoins[i];
            }
        }
        
        for (uint i = 0; i < popularTokens.length; i++) {
            bool isDuplicate = false;
            for (uint j = 0; j < idx; j++) {
                if (popularTokens[i] == allTokens[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                allTokens[idx++] = popularTokens[i];
            }
        }
        
        address[] memory result = new address[](idx);
        for (uint i = 0; i < idx; i++) {
            result[i] = allTokens[i];
        }
        
        return result;
    }

    function calculateTriangularOutput(uint amountIn, address[] memory path) internal view returns (uint finalOutput) {
        if (path.length != 4) return 0;
        
        uint currentAmount = amountIn;
        
        for (uint i = 0; i < path.length - 1; i++) {
            address tokenIn = path[i];
            address tokenOut = path[i + 1];
            
            (,uint bestOutput) = discoverOptimalPath(tokenIn, tokenOut, currentAmount);
            if (bestOutput == 0) return 0;
            currentAmount = bestOutput;
        }
        
        return currentAmount;
    }

    function findBestRoutersForPath(address[] memory path) internal view returns (address[] memory bestRouters) {
        bestRouters = new address[](path.length - 1);
        
        for (uint i = 0; i < path.length - 1; i++) {
            address tokenIn = path[i];
            address tokenOut = path[i + 1];
            
            address bestRouter = address(0);
            uint bestScore = 0;
            
            // Limit to top 3 routers for gas efficiency
            uint maxRouters = routers.length > 3 ? 3 : routers.length;
            for (uint r = 0; r < maxRouters; r++) {
                if (routers[r] == address(0)) continue;
                
                uint output = calculatePathOutput(1e18, getDirectPath(tokenIn, tokenOut));
                uint liquidity = getLiquidityScore(tokenIn, tokenOut, routers[r]);
                uint reliability = getRouterReliability(routers[r]);
                
                uint score = (output * liquidity * reliability) / 10000;
                
                if (score > bestScore) {
                    bestScore = score;
                    bestRouter = routers[r];
                }
            }
            
            bestRouters[i] = bestRouter;
        }
        
        return bestRouters;
    }

    function getLiquidityScore(address tokenA, address tokenB, address router) internal view returns (uint score) {
        try IUniswapV2Router02(router).factory() returns (address factory) {
            try IUniswapV2Factory(factory).getPair(tokenA, tokenB) returns (address pair) {
                if (pair != address(0)) {
                    try IUniswapV2Pair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
                        uint totalReserves = uint(reserve0) + uint(reserve1);
                        
                        if (totalReserves > 1e25) {
                            score = 100;
                        } else if (totalReserves > 1e24) {
                            score = 95;
                        } else if (totalReserves > 1e23) {
                            score = 85;
                        } else if (totalReserves > 1e22) {
                            score = 75;
                        } else if (totalReserves > 1e21) {
                            score = 60;
                        } else if (totalReserves > 1e20) {
                            score = 45;
                        } else if (totalReserves > 1e19) {
                            score = 30;
                        } else {
                            score = 15;
                        }
                        
                        // Apply token-specific bonuses
                        if (isStablecoin[tokenA] || isStablecoin[tokenB]) {
                            score = (score * 110) / 100;
                        }
                        
                        if (isPopularToken[tokenA] || isPopularToken[tokenB]) {
                            score = (score * 105) / 100;
                        }
                        
                        if (tokenA == WETH || tokenB == WETH) {
                            score = (score * 115) / 100;
                        }
                        
                    } catch {
                        score = 25;
                    }
                } else {
                    score = 5;
                }
            } catch {
                score = 25;
            }
        } catch {
            score = 25;
        }
        
        uint weightA = tokenLiquidityWeight[tokenA];
        uint weightB = tokenLiquidityWeight[tokenB];
        if (weightA > 0 || weightB > 0) {
            uint avgWeight = (weightA + weightB) / 2;
            score = (score * (100 + avgWeight / 10)) / 100;
        }
        
        if (score > 100) score = 100;
        return score;
    }

    function calculateRouterSlippage(uint amountIn, address tokenIn, address tokenOut, address router) internal view returns (uint slippage) {
        uint liquidityScore = getLiquidityScore(tokenIn, tokenOut, router);
        uint volume = getTokenVolume(tokenIn) + getTokenVolume(tokenOut);
        
        if (liquidityScore >= 95) {
            slippage = 5;
        } else if (liquidityScore >= 85) {
            slippage = 10;
        } else if (liquidityScore >= 75) {
            slippage = 20;
        } else if (liquidityScore >= 60) {
            slippage = 35;
        } else if (liquidityScore >= 45) {
            slippage = 50;
        } else if (liquidityScore >= 30) {
            slippage = 75;
        } else {
            slippage = 100;
        }
        
        if (volume > 1e24) {
            slippage = (slippage * 90) / 100;
        } else if (volume < 1e20) {
            slippage = (slippage * 120) / 100;
        }
        
        return slippage;
    }

    function getTokenVolume(address token) internal view returns (uint volume) {
        if (block.timestamp - lastVolumeUpdate[token] < 3600) {
            return tokenVolume24h[token];
        }
        
        if (token == WETH) {
            return 1e26;
        } else if (isStablecoin[token]) {
            return 1e25;
        } else if (isPopularToken[token]) {
            return 1e24;
        } else if (whitelistedTokens[token]) {
            return 1e23;
        } else {
            return 1e22;
        }
    }

    function getRouterReliability(address router) internal view returns (uint reliability) {
        try IUniswapV2Router02(router).factory() returns (address factory) {
            try IUniswapV2Factory(factory).allPairsLength() returns (uint pairCount) {
                if (pairCount > 10000) {
                    reliability = 100;
                } else if (pairCount > 5000) {
                    reliability = 90;
                } else if (pairCount > 1000) {
                    reliability = 80;
                } else if (pairCount > 100) {
                    reliability = 70;
                } else {
                    reliability = 60;
                }
            } catch {
                reliability = 50;
            }
        } catch {
            reliability = 50;
        }
        
        return reliability;
    }

    function calculateConfidenceScore(uint liquidity, uint volume) internal pure returns (uint confidence) {
        confidence = 0;
        
        if (liquidity >= 90) {
            confidence += 50;
        } else if (liquidity >= 70) {
            confidence += 40;
        } else if (liquidity >= 50) {
            confidence += 30;
        } else if (liquidity >= 30) {
            confidence += 20;
        } else {
            confidence += 10;
        }
        
        if (volume > 1e25) {
            confidence += 50;
        } else if (volume > 1e24) {
            confidence += 40;
        } else if (volume > 1e23) {
            confidence += 30;
        } else if (volume > 1e22) {
            confidence += 20;
        } else {
            confidence += 10;
        }
        
        return confidence;
    }

    function calculateTriangularConfidence(address[] memory path, address[] memory routers) internal view returns (uint confidence) {
        uint totalLiquidity = 0;
        uint validHops = 0;
        
        for (uint i = 0; i < path.length - 1 && i < routers.length; i++) {
            if (routers[i] != address(0)) {
                uint liquidity = getLiquidityScore(path[i], path[i + 1], routers[i]);
                totalLiquidity += liquidity;
                validHops++;
            }
        }
        
        if (validHops == 0) return 0;
        
        uint avgLiquidity = totalLiquidity / validHops;
        confidence = (avgLiquidity * 80) / 100;
        
        return confidence;
    }

    function calculatePathConfidence(address[] memory path, address[] memory routers) internal view returns (uint confidence) {
        uint totalLiquidity = 0;
        uint totalVolume = 0;
        uint validHops = 0;
        
        for (uint i = 0; i < path.length - 1 && i < routers.length; i++) {
            if (routers[i] != address(0)) {
                uint liquidity = getLiquidityScore(path[i], path[i + 1], routers[i]);
                uint volume = getTokenVolume(path[i]) + getTokenVolume(path[i + 1]);
                
                totalLiquidity += liquidity;
                totalVolume += volume;
                validHops++;
            }
        }
        
        if (validHops == 0) return 0;
        
        uint avgLiquidity = totalLiquidity / validHops;
        uint avgVolume = totalVolume / validHops;
        
        confidence = calculateConfidenceScore(avgLiquidity, avgVolume);
        
        if (path.length > 3) {
            confidence = (confidence * 90) / 100;
        }
        if (path.length > 4) {
            confidence = (confidence * 85) / 100;
        }
        
        return confidence;
    }

    function getDirectPath(address tokenA, address tokenB) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        return path;
    }

    function findBestRouterForPair(uint amountIn, address tokenIn, address tokenOut) internal view returns (address bestRouter, uint bestOutput) {
        bestRouter = address(0);
        bestOutput = 0;
        
        uint maxRouters = routers.length > 3 ? 3 : routers.length;
        for (uint r = 0; r < maxRouters; r++) {
            if (routers[r] == address(0)) continue;
            
            (,uint output) = discoverOptimalPath(tokenIn, tokenOut, amountIn);
            uint liquidity = getLiquidityScore(tokenIn, tokenOut, routers[r]);
            uint reliability = getRouterReliability(routers[r]);
            
            uint score = (output * liquidity * reliability) / 10000;
            
            if (score > bestOutput) {
                bestOutput = output;
                bestRouter = routers[r];
            }
        }
        
        return (bestRouter, bestOutput);
    }

    function buildOptimalTwoHopRoute(
        uint amountIn,
        address inputToken,
        address intermediate,
        address outputToken
    ) internal view returns (RouteCandidate memory candidate) {
        (uint firstHopOutput, Split[] memory firstHopSplits) = findOptimalSplitForPair(
            amountIn, inputToken, intermediate
        );

        if (firstHopOutput == 0 || firstHopSplits.length == 0) return candidate;

        (uint secondHopOutput, Split[] memory secondHopSplits) = findOptimalSplitForPair(
            firstHopOutput, intermediate, outputToken
        );

        if (secondHopOutput > 0 && secondHopSplits.length > 0) {
            TradeRoute memory route;
            route.inputToken = inputToken;
            route.outputToken = outputToken;
            route.hops = 2;
            route.splitRoutes = new Split[][](2);
            route.splitRoutes[0] = firstHopSplits;
            route.splitRoutes[1] = secondHopSplits;
            route.isArbitrage = false;
            route.totalGasEstimate = estimateGasForRoute(route);
            route.routeScore = calculateRouteScore(route, secondHopOutput);

            uint totalComplexity = firstHopSplits.length + secondHopSplits.length;
            uint liquidityScore = calculateRouteLiquidityScore(route);

            candidate = RouteCandidate({
                route: route,
                expectedOutput: secondHopOutput,
                hopCount: 2,
                complexity: totalComplexity,
                gasEstimate: route.totalGasEstimate,
                profitScore: calculateProfitScore(secondHopOutput, 2, totalComplexity, route.totalGasEstimate),
                liquidityScore: liquidityScore,
                diversificationScore: totalComplexity * 5
            });
        }
    }

    function buildOptimalThreeHopRoute(
        uint amountIn,
        address inputToken,
        address intermediate1,
        address intermediate2,
        address outputToken
    ) internal view returns (RouteCandidate memory candidate) {
        (uint firstHopOutput, Split[] memory firstHopSplits) = findOptimalSplitForPair(
            amountIn, inputToken, intermediate1
        );

        if (firstHopOutput == 0 || firstHopSplits.length == 0) return candidate;

        (uint secondHopOutput, Split[] memory secondHopSplits) = findOptimalSplitForPair(
            firstHopOutput, intermediate1, intermediate2
        );

        if (secondHopOutput == 0 || secondHopSplits.length == 0) return candidate;

        (uint thirdHopOutput, Split[] memory thirdHopSplits) = findOptimalSplitForPair(
            secondHopOutput, intermediate2, outputToken
        );

        if (thirdHopOutput > 0 && thirdHopSplits.length > 0) {
            TradeRoute memory route;
            route.inputToken = inputToken;
            route.outputToken = outputToken;
            route.hops = 3;
            route.splitRoutes = new Split[][](3);
            route.splitRoutes[0] = firstHopSplits;
            route.splitRoutes[1] = secondHopSplits;
            route.splitRoutes[2] = thirdHopSplits;
            route.isArbitrage = false;
            route.totalGasEstimate = estimateGasForRoute(route);
            route.routeScore = calculateRouteScore(route, thirdHopOutput);

            uint totalComplexity = firstHopSplits.length + secondHopSplits.length + thirdHopSplits.length;
            uint liquidityScore = calculateRouteLiquidityScore(route);

            candidate = RouteCandidate({
                route: route,
                expectedOutput: thirdHopOutput,
                hopCount: 3,
                complexity: totalComplexity,
                gasEstimate: route.totalGasEstimate,
                profitScore: calculateProfitScore(thirdHopOutput, 3, totalComplexity, route.totalGasEstimate),
                liquidityScore: liquidityScore,
                diversificationScore: totalComplexity * 3
            });
        }
    }

    function convertArbitrageToRoute(uint amountIn, ArbitrageOpportunity memory opportunity) internal view returns (RouteCandidate memory candidate) {
        if (opportunity.path.length < 2) return candidate;
        
        TradeRoute memory arbRoute;
        arbRoute.inputToken = opportunity.path[0];
        arbRoute.outputToken = opportunity.path[opportunity.path.length - 1];
        arbRoute.hops = opportunity.path.length - 1;
        arbRoute.isArbitrage = true;
        arbRoute.arbitrageProfitBps = opportunity.profitBps;
        
        arbRoute.splitRoutes = new Split[][](arbRoute.hops);
        
        for (uint i = 0; i < arbRoute.hops; i++) {
            arbRoute.splitRoutes[i] = new Split[](1);
            
            address routerToUse = i < opportunity.routers.length ? opportunity.routers[i] : opportunity.routers[0];
            (address[] memory hopPath,) = discoverOptimalPath(opportunity.path[i], opportunity.path[i + 1], amountIn);
            
            arbRoute.splitRoutes[i][0] = Split({
                router: routerToUse,
                percentage: 10000,
                path: hopPath,
                expectedOutput: 0,
                liquidityScore: getLiquidityScore(opportunity.path[i], opportunity.path[i + 1], routerToUse),
                gasEstimate: 80000 + (hopPath.length - 2) * 60000
            });
        }
        
        arbRoute.totalGasEstimate = estimateGasForRoute(arbRoute);
        uint expectedOutput = calculateRouteOutput(amountIn, arbRoute);
        arbRoute.routeScore = calculateRouteScore(arbRoute, expectedOutput);
        
        candidate = RouteCandidate({
            route: arbRoute,
            expectedOutput: expectedOutput,
            hopCount: arbRoute.hops,
            complexity: arbRoute.hops,
            gasEstimate: arbRoute.totalGasEstimate,
            profitScore: calculateProfitScore(expectedOutput, arbRoute.hops, arbRoute.hops, arbRoute.totalGasEstimate) + opportunity.profitBps,
            liquidityScore: calculateRouteLiquidityScore(arbRoute),
            diversificationScore: arbRoute.hops * 15
        });
        
        return candidate;
    }

    function selectOptimalRoute(
        RouteCandidate[] memory candidates,
        uint candidateCount
    ) internal pure returns (TradeRoute memory bestRoute, uint bestOutput) {
        if (candidateCount == 0) {
            return (TradeRoute({
                inputToken: address(0),
                outputToken: address(0),
                hops: 0,
                splitRoutes: new Split[][](0),
                isArbitrage: false,
                arbitrageProfitBps: 0,
                totalGasEstimate: 0,
                routeScore: 0
            }), 0);
        }

        uint bestScore = 0;
        bestOutput = 0;
        
        for (uint i = 0; i < candidateCount; i++) {
            RouteCandidate memory candidate = candidates[i];
            
            uint score = calculateCompositeRouteScore(candidate);
            
            if (score > bestScore || (score == bestScore && candidate.expectedOutput > bestOutput)) {
                bestScore = score;
                bestOutput = candidate.expectedOutput;
                bestRoute = candidate.route;
            }
        }
        
        return (bestRoute, bestOutput);
    }

    function calculateCompositeRouteScore(RouteCandidate memory candidate) internal pure returns (uint score) {
        uint profitComponent = candidate.profitScore * 40 / 100;
        uint liquidityComponent = candidate.liquidityScore * 25 / 100;
        uint gasComponent = candidate.gasEstimate < 300000 ? 100 * 20 / 100 : (500000 * 20) / (candidate.gasEstimate * 100);
        uint diversificationComponent = candidate.diversificationScore * 10 / 100;
        uint arbitrageBonus = candidate.route.isArbitrage ? candidate.route.arbitrageProfitBps * 5 / 100 : 0;
        
        score = profitComponent + liquidityComponent + gasComponent + diversificationComponent + arbitrageBonus;
        
        if (candidate.hopCount <= 2 && candidate.expectedOutput > 0) {
            score += 50;
        }
        
        return score;
    }

    function calculateRouteScore(TradeRoute memory route, uint expectedOutput) internal pure returns (uint score) {
        score = expectedOutput / 1e15;
        
        if (route.hops > 2) {
            score = (score * 95) / 100;
        }
        
        if (route.isArbitrage) {
            score += route.arbitrageProfitBps;
        }
        
        if (route.totalGasEstimate < 200000) {
            score = (score * 110) / 100;
        }
        
        return score;
    }

    function calculateRouteLiquidityScore(TradeRoute memory route) internal view returns (uint totalScore) {
        uint totalLiquidity = 0;
        uint totalSplits = 0;
        
        for (uint hopIndex = 0; hopIndex < route.hops; hopIndex++) {
            Split[] memory splits = route.splitRoutes[hopIndex];
            for (uint splitIndex = 0; splitIndex < splits.length; splitIndex++) {
                totalLiquidity += splits[splitIndex].liquidityScore;
                totalSplits++;
            }
        }
        
        if (totalSplits == 0) return 0;
        totalScore = totalLiquidity / totalSplits;
        
        return totalScore;
    }

    function calculateProfitScore(uint output, uint hops, uint complexity, uint gasEstimate) internal pure returns (uint score) {
        score = output / 1e15;
        
        if (hops > 1) {
            score = (score * (100 - (hops - 1) * 3)) / 100;
        }
        
        if (complexity > 3) {
            score = (score * (100 - (complexity - 3) * 2)) / 100;
        }
        
        if (gasEstimate < 150000) {
            score = (score * 115) / 100;
        } else if (gasEstimate < 250000) {
            score = (score * 105) / 100;
        } else if (gasEstimate > 500000) {
            score = (score * 85) / 100;
        }
        
        return score;
    }

    function estimateGasForRoute(TradeRoute memory route) internal pure returns (uint gasEstimate) {
        gasEstimate = 100000;
        gasEstimate += route.hops * 80000;
        
        for (uint i = 0; i < route.splitRoutes.length; i++) {
            gasEstimate += route.splitRoutes[i].length * 60000;
            
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                uint pathLength = route.splitRoutes[i][j].path.length;
                if (pathLength > 2) {
                    gasEstimate += (pathLength - 2) * 40000;
                }
            }
        }
        
        if (route.isArbitrage) {
            gasEstimate += 50000;
        }
        
        return gasEstimate;
    }

    function calculateRouteOutput(uint amountIn, TradeRoute memory route) internal view returns (uint finalOutput) {
        uint currentAmount = amountIn;
        
        for (uint hopIndex = 0; hopIndex < route.hops; hopIndex++) {
            Split[] memory splits = route.splitRoutes[hopIndex];
            uint hopOutput = 0;
            
            for (uint splitIndex = 0; splitIndex < splits.length; splitIndex++) {
                Split memory split = splits[splitIndex];
                uint splitAmount = (currentAmount * split.percentage) / 10000;
                
                if (splitAmount > 0) {
                    uint splitOutput = calculatePathOutput(splitAmount, split.path);
                    hopOutput += splitOutput;
                }
            }
            
            currentAmount = hopOutput;
            if (currentAmount == 0) return 0;
        }
        
        return currentAmount;
    }

    function calculateRouterCompositeScore(RouterOutput memory routerOutput) internal pure returns (uint score) {
        uint outputScore = routerOutput.output / 1e15;
        uint liquidityScore = routerOutput.liquidityScore;
        uint reliabilityScore = routerOutput.reliabilityScore;
        uint gasEfficiencyScore = routerOutput.gasEstimate < 150000 ? 100 : (200000 * 100) / routerOutput.gasEstimate;
        
        score = (outputScore * 50 + liquidityScore * 25 + reliabilityScore * 15 + gasEfficiencyScore * 10) / 100;
        return score;
    }

    function calculateCombinationOutput(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        RouterOutput[] memory testRouters,
        uint[] memory percentages
    ) internal view returns (uint totalOutput) {
        totalOutput = 0;

        for (uint i = 0; i < testRouters.length; i++) {
            if (testRouters[i].router == address(0) || percentages[i] == 0) continue;

            uint routerAmountIn = (amountIn * percentages[i]) / 10000;
            if (routerAmountIn == 0) continue;

            (address[] memory path, uint routerOutput) = discoverOptimalPath(tokenIn, tokenOut, routerAmountIn);
            if (routerOutput > 0) {
                uint adjustedOutput = (routerOutput * testRouters[i].liquidityScore * testRouters[i].reliabilityScore) / 10000;
                totalOutput += adjustedOutput;
            }
        }

        return totalOutput;
    }

    // **ENHANCED SLIPPAGE AND EXECUTION**
    function calculateDynamicSlippage(address inputToken, address outputToken, uint expectedOut) internal view returns (uint slippageBps) {
        slippageBps = defaultSlippageBps;

        if (expectedOut > 0) {
            uint avgLiquidityScore = 0;
            uint validRouters = 0;
            
            for (uint i = 0; i < routers.length; i++) {
                if (routers[i] != address(0)) {
                    uint liquidity = getLiquidityScore(inputToken, outputToken, routers[i]);
                    avgLiquidityScore += liquidity;
                    validRouters++;
                }
            }
            
            if (validRouters > 0) {
                avgLiquidityScore = avgLiquidityScore / validRouters;
                
                if (avgLiquidityScore > 85) {
                    slippageBps = arbitrageSlippageBps;
                    return slippageBps;
                }
            }
        }

        if (isStablecoin[inputToken] && isStablecoin[outputToken]) {
            slippageBps = minSlippageBps;
            return slippageBps;
        }

        if (inputToken == WETH || outputToken == WETH) {
            slippageBps = (defaultSlippageBps * 80) / 100;
            return slippageBps;
        }

        if (isPopularToken[inputToken] && isPopularToken[outputToken]) {
            slippageBps = (defaultSlippageBps * 90) / 100;
            return slippageBps;
        }

        if (!whitelistedTokens[inputToken] || !whitelistedTokens[outputToken]) {
            slippageBps = maxSlippageBps;
            return slippageBps;
        }

        return slippageBps;
    }

    function calculateMinAmountOut(uint expectedOut, address inputToken, address outputToken) internal view returns (uint minAmountOut) {
        uint slippageBps = calculateDynamicSlippage(inputToken, outputToken, expectedOut);

        if (slippageBps < minSlippageBps) {
            slippageBps = minSlippageBps;
        } else if (slippageBps > maxSlippageBps) {
            slippageBps = maxSlippageBps;
        }

        minAmountOut = (expectedOut * (10000 - slippageBps)) / 10000;
    }

    // **EXECUTION WITH ENHANCED DYNAMIC SUPPORT**
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

        for (uint i = 0; i < route.hops; i++) {
            require(route.splitRoutes[i].length > 0 && route.splitRoutes[i].length <= MAX_SPLITS_PER_HOP, "Invalid split count");
            
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                Split memory split = route.splitRoutes[i][j];
                require(split.router != address(0), "Invalid router");
                require(split.path.length >= 2, "Invalid path length");

                for (uint k = 0; k < split.path.length; k++) {
                    address token = split.path[k];
                    require(token != address(0), "Invalid token in path");

                    if (token != route.inputToken && token != route.outputToken && token != WETH) {
                        require(whitelistedTokens[token], "Intermediate token not whitelisted");
                    }
                }
            }
        }

        if (route.isArbitrage) {
            bytes32 routeHash = keccak256(abi.encodePacked(route.inputToken, route.outputToken, route.hops, route.arbitrageProfitBps));
            require(
                block.timestamp >= lastArbitrageTimestamp[routeHash] + ARBITRAGE_COOLDOWN,
                "Arbitrage cooldown active"
            );
            lastArbitrageTimestamp[routeHash] = block.timestamp;
        }

        bool isETHInput = msg.value > 0;

        if (isETHInput) {
            require(route.inputToken == WETH, "Input token must be WETH for ETH input");
            require(msg.value == amountIn, "ETH amount doesn't match amountIn");
            IWETH(WETH).deposit{value: amountIn}();
        } else {
            require(IERC20(route.inputToken).transferFrom(msg.sender, address(this), amountIn), "Transfer failed");
        }

        uint fee = amountIn / FEE_DIVISOR;
        uint remainingAmount = amountIn - fee;

        if (isETHInput) {
            feeAccumulatedETH += fee;
        } else {
            feeAccumulatedTokens[route.inputToken] += fee;
        }

        address currentToken = route.inputToken;
        amountOut = remainingAmount;

        for (uint hopIndex = 0; hopIndex < route.hops; hopIndex++) {
            Split[] memory splits = route.splitRoutes[hopIndex];

            uint nextAmountOut = 0;
            address nextToken = splits[0].path[splits[0].path.length - 1];

            for (uint i = 1; i < splits.length; i++) {
                require(
                    splits[i].path[splits[i].path.length - 1] == nextToken,
                    "Inconsistent paths in splits"
                );
            }

            for (uint splitIndex = 0; splitIndex < splits.length; splitIndex++) {
                Split memory split = splits[splitIndex];
                if (split.router == address(0) || split.percentage == 0) continue;

                uint splitAmount = (amountOut * split.percentage) / 10000;
                if (splitAmount == 0) continue;

                uint splitMinAmountOut = 0;

                if (hopIndex == route.hops - 1) {
                    if (splits.length == 1) {
                        splitMinAmountOut = amountOutMin;
                    } else {
                        if (amountOutMin == 0) {
                            uint expectedSplitOut = calculatePathOutput(splitAmount, split.path);
                            splitMinAmountOut = calculateMinAmountOut(expectedSplitOut, currentToken, nextToken);
                        } else {
                            splitMinAmountOut = (amountOutMin * split.percentage) / 10000;
                        }
                    }
                }

                uint[] memory amountsOut = executeSwapStep(
                    splitAmount,
                    splitMinAmountOut,
                    split,
                    currentToken,
                    nextToken,
                    deadline,
                    isETHInput && hopIndex == 0,
                    nextToken == WETH && hopIndex == route.hops - 1
                );

                if (amountsOut.length > 0) {
                    nextAmountOut += amountsOut[amountsOut.length - 1];
                }
            }

            currentToken = nextToken;
            amountOut = nextAmountOut;

            require(amountOut > 0, "Zero output from hop");
        }

        if (amountOutMin > 0) {
            require(amountOut >= amountOutMin, "Insufficient output amount");
        }

        if (route.outputToken == WETH) {
            IWETH(WETH).withdraw(amountOut);
            payable(msg.sender).transfer(amountOut);
        } else {
            require(IERC20(route.outputToken).transfer(msg.sender, amountOut), "Output transfer failed");
        }

        if (route.isArbitrage) {
            uint profit = amountOut > amountIn ? amountOut - amountIn : 0;
            uint profitBps = profit > 0 ? (profit * 10000) / amountIn : 0;
            emit ArbitrageExecuted(msg.sender, profit, profitBps);
        }

        emit SwapExecuted(msg.sender, amountIn, amountOut);
    }

    function executeSwapStep(
        uint splitAmount,
        uint splitMinAmountOut,
        Split memory split,
        address currentToken,
        address nextToken,
        uint deadline,
        bool isETHInput,
        bool isETHOutput
    ) internal returns (uint[] memory amountsOut) {
        if (isETHInput) {
            IWETH(WETH).withdraw(splitAmount);
            try IUniswapV2Router02(split.router).swapExactETHForTokens{value: splitAmount}(
                splitMinAmountOut,
                split.path,
                address(this),
                deadline
            ) returns (uint[] memory amounts) {
                amountsOut = amounts;
            } catch {
                amountsOut = new uint[](0);
            }
        } 
        else if (isETHOutput) {
            try IERC20(currentToken).approve(split.router, splitAmount) returns (bool) {} catch {
                amountsOut = new uint[](0);
                return amountsOut;
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
                amountsOut = new uint[](0);
            }
        } 
        else {
            try IERC20(currentToken).approve(split.router, splitAmount) returns (bool) {} catch {
                amountsOut = new uint[](0);
                return amountsOut;
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
                amountsOut = new uint[](0);
            }
        }

        return amountsOut;
    }

    // **VIEW FUNCTIONS FOR DYNAMIC TOKEN MANAGEMENT**
    function getIntermediateTokens() external view returns (address[] memory) {
        return intermediateTokens;
    }

    function getStablecoins() external view returns (address[] memory) {
        return stablecoins;
    }

    function getPopularTokens() external view returns (address[] memory) {
        return popularTokens;
    }

    function getRouters() external view returns (address[] memory) {
        return routers;
    }

    function isWhitelisted(address token) public view returns (bool) {
        return whitelistedTokens[token];
    }

    // **FEE MANAGEMENT**
    function withdrawFeesETH() external onlyOwner {
        uint amount = feeAccumulatedETH;
        require(amount > 0, "No ETH fees");
        feeAccumulatedETH = 0;
        payable(owner).transfer(amount);
    }

    function withdrawFeesToken(address token) external onlyOwner {
        uint amount = feeAccumulatedTokens[token];
        require(amount > 0, "No token fees");
        feeAccumulatedTokens[token] = 0;
        require(IERC20(token).transfer(owner, amount), "Transfer failed");
    }

    function updateSlippageConfig(uint _defaultSlippageBps, uint _minSlippageBps, uint _maxSlippageBps) external onlyOwner {
        require(_minSlippageBps <= _defaultSlippageBps && _defaultSlippageBps <= _maxSlippageBps, "Invalid slippage config");
        defaultSlippageBps = _defaultSlippageBps;
        minSlippageBps = _minSlippageBps;
        maxSlippageBps = _maxSlippageBps;
    }

    function updateTokenLiquidityWeight(address token, uint weight) external onlyOwner {
        tokenLiquidityWeight[token] = weight;
        emit LiquidityUpdated(token, weight);
    }

    receive() external payable {}
}
