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

    struct RouteCandidate {
        TradeRoute route;
        uint expectedOutput;
        uint hopCount;
        uint complexity;
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

    function canUseTokenInRoute(address token, address inputToken, address outputToken, bool isIntermediateToken) internal view returns (bool) {
        if (token == inputToken || token == outputToken) {
            return true;
        }

        if (isIntermediateToken) {
            return isWhitelisted(token);
        }

        return true;
    }

    // Enhanced findBestRoute that comprehensively compares ALL possible routes
    function findBestRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (TradeRoute memory route, uint expectedOut) {
        require(amountIn > 0, "Amount must be greater than 0");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(inputToken != outputToken, "Input and output tokens must be different");
        require(routers.length > 0, "No routers configured");

        RouteCandidate[] memory candidates = new RouteCandidate[](200); // Store up to 200 route candidates
        uint candidateCount = 0;

        // 1. Direct routes (1-hop) with dynamic splits
        for (uint i = 0; i < routers.length && candidateCount < 190; i++) {
            if (routers[i] == address(0)) continue;

            (uint directOutput, Split[] memory directSplits) = findOptimalSplitForPair(
                amountIn,
                inputToken,
                outputToken
            );

            if (directOutput > 0 && directSplits.length > 0) {
                TradeRoute memory directRoute;
                directRoute.inputToken = inputToken;
                directRoute.outputToken = outputToken;
                directRoute.hops = 1;
                directRoute.splitRoutes = new Split[][](1);
                directRoute.splitRoutes[0] = directSplits;

                candidates[candidateCount] = RouteCandidate({
                    route: directRoute,
                    expectedOutput: directOutput,
                    hopCount: 1,
                    complexity: directSplits.length
                });
                candidateCount++;
            }
        }

        // 2. Multi-hop routes (2, 3, 4 hops) with comprehensive path exploration
        address[] memory intermediateTokens = getAllPotentialIntermediates();

        // 2-hop routes with all possible intermediates
        candidateCount = exploreMultiHopRoutes(
            amountIn, inputToken, outputToken, 2, 
            intermediateTokens, candidates, candidateCount
        );

        // 3-hop routes
        candidateCount = exploreMultiHopRoutes(
            amountIn, inputToken, outputToken, 3, 
            intermediateTokens, candidates, candidateCount
        );

        // 4-hop routes
        candidateCount = exploreMultiHopRoutes(
            amountIn, inputToken, outputToken, 4, 
            intermediateTokens, candidates, candidateCount
        );

        // 3. Find the absolute best route from all candidates
        uint bestOutput = 0;
        TradeRoute memory bestRoute;

        for (uint i = 0; i < candidateCount; i++) {
            if (candidates[i].expectedOutput > bestOutput) {
                bestOutput = candidates[i].expectedOutput;
                bestRoute = candidates[i].route;
            }
        }

        if (bestOutput > 0) {
            return (bestRoute, bestOutput);
        } else {
            // Return empty route
            return (TradeRoute({
                inputToken: inputToken,
                outputToken: outputToken,
                hops: 0,
                splitRoutes: new Split[][](0)
            }), 0);
        }
    }

    // Explore all multi-hop routes systematically
    function exploreMultiHopRoutes(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint targetHops,
        address[] memory intermediateTokens,
        RouteCandidate[] memory candidates,
        uint currentCandidateCount
    ) internal view returns (uint newCandidateCount) {
        newCandidateCount = currentCandidateCount;

        if (targetHops == 2) {
            // 2-hop: input -> intermediate -> output
            for (uint i = 0; i < intermediateTokens.length && newCandidateCount < 195; i++) {
                address intermediate = intermediateTokens[i];
                if (intermediate == address(0) || intermediate == inputToken || intermediate == outputToken) continue;

                RouteCandidate memory candidate = buildTwoHopRoute(amountIn, inputToken, intermediate, outputToken);
                if (candidate.expectedOutput > 0) {
                    candidates[newCandidateCount] = candidate;
                    newCandidateCount++;
                }
            }
        } else if (targetHops == 3) {
            // 3-hop: input -> intermediate1 -> intermediate2 -> output
            for (uint i = 0; i < intermediateTokens.length && newCandidateCount < 195; i++) {
                address intermediate1 = intermediateTokens[i];
                if (intermediate1 == address(0) || intermediate1 == inputToken || intermediate1 == outputToken) continue;

                for (uint j = 0; j < intermediateTokens.length && newCandidateCount < 195; j++) {
                    address intermediate2 = intermediateTokens[j];
                    if (intermediate2 == address(0) || intermediate2 == inputToken || 
                        intermediate2 == outputToken || intermediate2 == intermediate1) continue;

                    RouteCandidate memory candidate = buildThreeHopRoute(
                        amountIn, inputToken, intermediate1, intermediate2, outputToken
                    );
                    if (candidate.expectedOutput > 0) {
                        candidates[newCandidateCount] = candidate;
                        newCandidateCount++;
                    }
                }
            }
        } else if (targetHops == 4) {
            // 4-hop: input -> intermediate1 -> intermediate2 -> intermediate3 -> output
            for (uint i = 0; i < intermediateTokens.length && newCandidateCount < 195; i++) {
                address intermediate1 = intermediateTokens[i];
                if (intermediate1 == address(0) || intermediate1 == inputToken || intermediate1 == outputToken) continue;

                for (uint j = 0; j < intermediateTokens.length && newCandidateCount < 195; j++) {
                    address intermediate2 = intermediateTokens[j];
                    if (intermediate2 == address(0) || intermediate2 == inputToken || 
                        intermediate2 == outputToken || intermediate2 == intermediate1) continue;

                    for (uint k = 0; k < intermediateTokens.length && newCandidateCount < 195; k++) {
                        address intermediate3 = intermediateTokens[k];
                        if (intermediate3 == address(0) || intermediate3 == inputToken || 
                            intermediate3 == outputToken || intermediate3 == intermediate1 || 
                            intermediate3 == intermediate2) continue;

                        RouteCandidate memory candidate = buildFourHopRoute(
                            amountIn, inputToken, intermediate1, intermediate2, intermediate3, outputToken
                        );
                        if (candidate.expectedOutput > 0) {
                            candidates[newCandidateCount] = candidate;
                            newCandidateCount++;
                        }
                    }
                }
            }
        }

        return newCandidateCount;
    }

    // Build optimized 2-hop route
    function buildTwoHopRoute(
        uint amountIn,
        address inputToken,
        address intermediate,
        address outputToken
    ) internal view returns (RouteCandidate memory candidate) {
        // First hop with dynamic splits
        (uint firstHopOutput, Split[] memory firstHopSplits) = findOptimalSplitForPair(
            amountIn, inputToken, intermediate
        );

        if (firstHopOutput == 0 || firstHopSplits.length == 0) {
            return candidate; // Returns empty candidate
        }

        // Second hop with dynamic splits
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

            candidate = RouteCandidate({
                route: route,
                expectedOutput: secondHopOutput,
                hopCount: 2,
                complexity: firstHopSplits.length + secondHopSplits.length
            });
        }
    }

    // Build optimized 3-hop route
    function buildThreeHopRoute(
        uint amountIn,
        address inputToken,
        address intermediate1,
        address intermediate2,
        address outputToken
    ) internal view returns (RouteCandidate memory candidate) {
        // First hop
        (uint firstHopOutput, Split[] memory firstHopSplits) = findOptimalSplitForPair(
            amountIn, inputToken, intermediate1
        );

        if (firstHopOutput == 0 || firstHopSplits.length == 0) return candidate;

        // Second hop
        (uint secondHopOutput, Split[] memory secondHopSplits) = findOptimalSplitForPair(
            firstHopOutput, intermediate1, intermediate2
        );

        if (secondHopOutput == 0 || secondHopSplits.length == 0) return candidate;

        // Third hop
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

            candidate = RouteCandidate({
                route: route,
                expectedOutput: thirdHopOutput,
                hopCount: 3,
                complexity: firstHopSplits.length + secondHopSplits.length + thirdHopSplits.length
            });
        }
    }

    // Build optimized 4-hop route
    function buildFourHopRoute(
        uint amountIn,
        address inputToken,
        address intermediate1,
        address intermediate2,
        address intermediate3,
        address outputToken
    ) internal view returns (RouteCandidate memory candidate) {
        // First hop
        (uint firstHopOutput, Split[] memory firstHopSplits) = findOptimalSplitForPair(
            amountIn, inputToken, intermediate1
        );

        if (firstHopOutput == 0 || firstHopSplits.length == 0) return candidate;

        // Second hop
        (uint secondHopOutput, Split[] memory secondHopSplits) = findOptimalSplitForPair(
            firstHopOutput, intermediate1, intermediate2
        );

        if (secondHopOutput == 0 || secondHopSplits.length == 0) return candidate;

        // Third hop
        (uint thirdHopOutput, Split[] memory thirdHopSplits) = findOptimalSplitForPair(
            secondHopOutput, intermediate2, intermediate3
        );

        if (thirdHopOutput == 0 || thirdHopSplits.length == 0) return candidate;

        // Fourth hop
        (uint fourthHopOutput, Split[] memory fourthHopSplits) = findOptimalSplitForPair(
            thirdHopOutput, intermediate3, outputToken
        );

        if (fourthHopOutput > 0 && fourthHopSplits.length > 0) {
            TradeRoute memory route;
            route.inputToken = inputToken;
            route.outputToken = outputToken;
            route.hops = 4;
            route.splitRoutes = new Split[][](4);
            route.splitRoutes[0] = firstHopSplits;
            route.splitRoutes[1] = secondHopSplits;
            route.splitRoutes[2] = thirdHopSplits;
            route.splitRoutes[3] = fourthHopSplits;

            candidate = RouteCandidate({
                route: route,
                expectedOutput: fourthHopOutput,
                hopCount: 4,
                complexity: firstHopSplits.length + secondHopSplits.length + thirdHopSplits.length + fourthHopSplits.length
            });
        }
    }

    // Enhanced optimal split finding with dynamic percentages (1-100%)
    function findOptimalSplitForPair(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) public view returns (uint bestOutput, Split[] memory bestSplits) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (0, new Split[](0));
        }

        // Get all router outputs and rank them
        RouterOutput[] memory routerOutputs = new RouterOutput[](routers.length);
        uint validRouterCount = 0;

        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;

            uint output = getRouterOutput(amountIn, tokenIn, tokenOut, routers[i]);
            if (output > 0) {
                routerOutputs[validRouterCount] = RouterOutput({
                    router: routers[i],
                    output: output,
                    index: i
                });
                validRouterCount++;
            }
        }

        if (validRouterCount == 0) return (0, new Split[](0));

        // Sort routers by output (descending)
        for (uint i = 0; i < validRouterCount - 1; i++) {
            for (uint j = i + 1; j < validRouterCount; j++) {
                if (routerOutputs[j].output > routerOutputs[i].output) {
                    RouterOutput memory temp = routerOutputs[i];
                    routerOutputs[i] = routerOutputs[j];
                    routerOutputs[j] = temp;
                }
            }
        }

        // Test single router (100% allocation)
        bestOutput = routerOutputs[0].output;
        bestSplits = new Split[](1);
        bestSplits[0] = Split({
            router: routerOutputs[0].router,
            percentage: 10000, // 100%
            path: getOptimalPath(tokenIn, tokenOut)
        });

        // Test combinations with dynamic percentage optimization
        if (validRouterCount >= 2) {
            // Test all possible router combinations up to MAX_SPLITS_PER_HOP
            uint maxCombinations = validRouterCount < MAX_SPLITS_PER_HOP ? validRouterCount : MAX_SPLITS_PER_HOP;

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

    struct RouterOutput {
        address router;
        uint output;
        uint index;
    }

    // Find optimal combination of routers with dynamic percentages
    function findOptimalCombination(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        RouterOutput[] memory routerOutputs,
        uint combSize,
        uint validRouterCount
    ) internal view returns (uint bestOutput, Split[] memory bestSplits) {
        bestOutput = 0;

        // Generate all possible percentage distributions
        uint[][] memory percentageDistributions = generateDynamicPercentages(combSize);

        // Test each combination of top routers
        for (uint startIdx = 0; startIdx <= validRouterCount - combSize; startIdx++) {
            address[] memory testRouters = new address[](combSize);
            for (uint i = 0; i < combSize; i++) {
                testRouters[i] = routerOutputs[startIdx + i].router;
            }

            // Test each percentage distribution
            for (uint distIdx = 0; distIdx < percentageDistributions.length; distIdx++) {
                uint[] memory percentages = percentageDistributions[distIdx];
                if (percentages.length != combSize) continue;

                uint totalOutput = calculateCombinationOutput(
                    amountIn, tokenIn, tokenOut, testRouters, percentages
                );

                if (totalOutput > bestOutput) {
                    bestOutput = totalOutput;
                    bestSplits = new Split[](combSize);
                    address[] memory path = getOptimalPath(tokenIn, tokenOut);

                    for (uint i = 0; i < combSize; i++) {
                        bestSplits[i] = Split({
                            router: testRouters[i],
                            percentage: percentages[i],
                            path: path
                        });
                    }
                }
            }
        }

        return (bestOutput, bestSplits);
    }

    // Generate dynamic percentage distributions (1-100% per router)
    function generateDynamicPercentages(uint routerCount) internal pure returns (uint[][] memory) {
        if (routerCount == 1) {
            uint[][] memory result = new uint[][](1);
            result[0] = new uint[](1);
            result[0][0] = 10000; // 100%
            return result;
        }

        if (routerCount == 2) {
            uint[][] memory result = new uint[][](99);
            uint idx = 0;

            // Generate 1%-99% splits for first router, remainder for second
            for (uint pct1 = 100; pct1 <= 9900; pct1 += 100) { // 1% to 99% in 1% increments
                result[idx] = new uint[](2);
                result[idx][0] = pct1;
                result[idx][1] = 10000 - pct1;
                idx++;
            }
            return result;
        }

        if (routerCount == 3) {
            uint[][] memory result = new uint[][](45);
            uint idx = 0;

            // Generate combinations where sum = 100%
            for (uint pct1 = 1000; pct1 <= 8000; pct1 += 1000) { // 10% to 80%
                for (uint pct2 = 1000; pct2 <= 9000 - pct1; pct2 += 1000) {
                    uint pct3 = 10000 - pct1 - pct2;
                    if (pct3 >= 1000 && idx < 45) { // At least 10%
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

        if (routerCount == 4) {
            uint[][] memory result = new uint[][](20);
            uint idx = 0;

            // Generate balanced combinations
            uint[20][4] memory presets = [
                [2500, 2500, 2500, 2500], // Equal split
                [4000, 2000, 2000, 2000], // Weighted to first
                [3500, 2500, 2000, 2000],
                [3000, 3000, 2000, 2000],
                [5000, 2000, 1500, 1500],
                [4500, 2500, 1500, 1500],
                [4000, 3000, 1500, 1500],
                [3500, 3000, 2000, 1500],
                [6000, 1500, 1250, 1250],
                [5500, 2000, 1250, 1250],
                [5000, 2500, 1250, 1250],
                [4500, 2500, 1500, 1500],
                [7000, 1000, 1000, 1000],
                [6500, 1500, 1000, 1000],
                [6000, 2000, 1000, 1000],
                [5500, 2000, 1250, 1250],
                [8000, 700, 650, 650],
                [7500, 1000, 750, 750],
                [7000, 1200, 900, 900],
                [6500, 1500, 1000, 1000]
            ];

            for (uint i = 0; i < 20; i++) {
                result[idx] = new uint[](4);
                for (uint j = 0; j < 4; j++) {
                    result[idx][j] = presets[i][j];
                }
                idx++;
            }
            return result;
        }

        // Fallback for other sizes
        uint[][] memory result = new uint[][](1);
        result[0] = new uint[](routerCount);
        uint equalShare = 10000 / routerCount;
        for (uint i = 0; i < routerCount; i++) {
            result[0][i] = equalShare;
        }
        // Adjust last element for rounding
        result[0][routerCount - 1] = 10000 - (equalShare * (routerCount - 1));
        return result;
    }

    // Calculate output for a specific router combination
    function calculateCombinationOutput(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory testRouters,
        uint[] memory percentages
    ) internal view returns (uint totalOutput) {
        totalOutput = 0;
        address[] memory path = getOptimalPath(tokenIn, tokenOut);

        for (uint i = 0; i < testRouters.length; i++) {
            if (testRouters[i] == address(0) || percentages[i] == 0) continue;

            uint routerAmountIn = (amountIn * percentages[i]) / 10000;
            if (routerAmountIn == 0) continue;

            try IUniswapV2Router02(testRouters[i]).getAmountsOut(routerAmountIn, path) returns (uint[] memory amounts) {
                if (amounts.length > 1) {
                    totalOutput += amounts[amounts.length - 1];
                }
            } catch {
                // Skip if router fails
            }
        }

        return totalOutput;
    }

    // Get output for a specific router
    function getRouterOutput(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address router
    ) internal view returns (uint output) {
        address[] memory path = getOptimalPath(tokenIn, tokenOut);

        try IUniswapV2Router02(router).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
            if (amounts.length > 1) {
                output = amounts[amounts.length - 1];
            }
        } catch {
            output = 0;
        }

        return output;
    }

    // Get all potential intermediate tokens for routing
    function getAllPotentialIntermediates() internal view returns (address[] memory) {
        address[] memory commonTokens = getCommonIntermediates();
        address[] memory stablecoins = getCommonStablecoins();

        // Create expanded list including input/output tokens as potential intermediates
        address[] memory allTokens = new address[](commonTokens.length + stablecoins.length);

        uint idx = 0;
        for (uint i = 0; i < commonTokens.length; i++) {
            allTokens[idx++] = commonTokens[i];
        }

        for (uint i = 0; i < stablecoins.length; i++) {
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

        // Create final array with only filled elements
        address[] memory result = new address[](idx);
        for (uint i = 0; i < idx; i++) {
            result[i] = allTokens[i];
        }

        return result;
    }

    function getCommonIntermediates() internal view returns (address[] memory) {
        address[] memory intermediates = new address[](5);
        intermediates[0] = WETH;
        intermediates[1] = address(0xE0590015A873bF326bd645c3E1266d4db41C4E6B);
        intermediates[2] = address(0x0F0BDEbF0F83cD1EE3974779Bcb7315f9808c714);
        intermediates[3] = address(0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D);
        intermediates[4] = address(0xf817257fed379853cDe0fa4F97AB987181B1E5Ea);
        return intermediates;
    }

    function getCommonStablecoins() public pure returns (address[] memory) {
        address[] memory stablecoins = new address[](4);
        stablecoins[0] = address(0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D);
        stablecoins[1] = address(0xf817257fed379853cDe0fa4F97AB987181B1E5Ea);
        stablecoins[2] = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        stablecoins[3] = address(0x0000000000085d4780B73119b644AE5ecd22b376);
        return stablecoins;
    }

    function getOptimalPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
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

        // Check if direct path has liquidity on any router
        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;

            try IUniswapV2Router02(routers[i]).getAmountsOut(1, directPath) returns (uint[] memory amounts) {
                if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                    return directPath;
                }
            } catch {
                continue;
            }
        }

        // Try WETH path
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
                    continue;
                }
            }
        }

        return directPath; // Fallback
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

    function calculateDynamicSlippage(address inputToken, address outputToken, uint expectedOut) internal view returns (uint slippageBps) {
        slippageBps = defaultSlippageBps;

        uint8 decimalsOut = 18;
        try IERC20(outputToken).decimals() returns (uint8 dec) {
            decimalsOut = dec;
        } catch {}

        if (decimalsOut >= 9 && expectedOut < 10 ** (decimalsOut - 6)) {
            slippageBps = maxSlippageBps;
            return slippageBps;
        }

        if (inputToken == WETH || outputToken == WETH) {
            return slippageBps;
        }

        if (!isWhitelisted(inputToken) && !isWhitelisted(outputToken)) {
            slippageBps = maxSlippageBps;
            return slippageBps;
        }

        if (!isWhitelisted(inputToken) || !isWhitelisted(outputToken)) {
            slippageBps = (defaultSlippageBps + maxSlippageBps) / 2;
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

                for (uint k = 0; k < split.path.length; k++) {
                    address token = split.path[k];
                    require(token != address(0), "Invalid token in path");

                    if (token == route.inputToken || token == route.outputToken) {
                        continue;
                    } else {
                        require(isWhitelisted(token), "Intermediate token not whitelisted");
                    }
                }
            }
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
            require(splits.length > 0 && splits.length <= MAX_SPLITS_PER_HOP, "Invalid split count");

            if (hopIndex < route.hops - 1) {
                address currentNextToken = splits[0].path[splits[0].path.length - 1];
                for (uint i = 1; i < splits.length; i++) {
                    require(
                        splits[i].path[splits[i].path.length - 1] == currentNextToken,
                        "Inconsistent paths in splits"
                    );
                }

                if (currentNextToken != route.outputToken && currentNextToken != route.inputToken) {
                    require(isWhitelisted(currentNextToken), "Intermediate token not whitelisted");
                }
            }

            uint nextAmountOut = 0;
            address nextToken = splits[0].path[splits[0].path.length - 1];

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
                            uint[] memory amountsInner;
                            try IUniswapV2Router02(split.router).getAmountsOut(splitAmount, split.path) returns (uint[] memory res) {
                                amountsInner = res;
                                uint expectedSplitOut = amountsInner[amountsInner.length - 1];
                                splitMinAmountOut = calculateMinAmountOut(expectedSplitOut, currentToken, nextToken);
                            } catch {
                                splitMinAmountOut = splitAmount / 2;
                            }
                        } else {
                            splitMinAmountOut = (amountOutMin * split.percentage) / 10000;
                        }
                    }
                }

                uint[] memory amountsOut;

                if (hopIndex == 0 && isETHInput) {
                    IWETH(WETH).withdraw(splitAmount);

                    try IUniswapV2Router02(split.router).swapExactETHForTokens{value: splitAmount}(
                        splitMinAmountOut,
                        split.path,
                        address(this),
                        deadline
                    ) returns (uint[] memory amounts) {
                        amountsOut = amounts;
                    } catch {
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
                        continue;
                    }
                }

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
            require(IERC20(route.outputToken).transfer(msg.sender, amountOut), "Output transfer failed");
        }

        emit SwapExecuted(msg.sender, amountIn, amountOut);
    }

    receive() external payable {}
}