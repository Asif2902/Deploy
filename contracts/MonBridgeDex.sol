
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
    uint public constant MAX_ROUTERS = 15;
    uint public constant MAX_HOPS = 8; // Increased from 4 to 8
    uint public constant MAX_SPLITS_PER_HOP = 6; // Increased for better optimization

    // Default slippage tolerance in basis points (0.5%)
    uint public defaultSlippageBps = 50;
    // Minimum acceptable slippage tolerance in basis points (0.1%)
    uint public minSlippageBps = 10;
    // Maximum slippage tolerance for high volatility tokens (5%)
    uint public maxSlippageBps = 500;

    uint public constant SPLIT_THRESHOLD_BPS = 30; // Reduced threshold for more aggressive splitting
    uint public constant FEE_DIVISOR = 1000; 

    // Advanced optimization parameters
    uint public constant GENETIC_POPULATION_SIZE = 20;
    uint public constant GENETIC_GENERATIONS = 10;
    uint public constant BRUTE_FORCE_LIMIT = 1000;
    uint public constant LINEAR_PROGRAMMING_ITERATIONS = 50;

    uint public feeAccumulatedETH;
    mapping(address => uint) public feeAccumulatedTokens;
    address public WETH;

    mapping(address => bool) public whitelistedTokens;

    // Advanced routing state
    mapping(bytes32 => uint) public routeCache;
    uint public cacheTimeout = 300; // 5 minutes

    // Storage for DP memoization
    mapping(bytes32 => uint) private dpMemoization;

    // Arbitrage detection structures
    struct ArbitrageOpportunity {
        address[] cycle;
        uint[] amounts;
        uint profit;
        uint profitability; // Profit as percentage * 100
        bool isTriangular;
    }

    struct ArbitrageRoute {
        ArbitrageOpportunity[] opportunities;
        uint totalProfit;
        uint enhancedOutput;
    }

    // Arbitrage configuration
    uint public constant MIN_ARBITRAGE_PROFIT_BPS = 50; // 0.5%
    uint public constant MAX_ARBITRAGE_CYCLES = 5;
    uint public constant TRIANGULAR_CYCLE_LENGTH = 3;
    uint public constant MAX_CYCLE_LENGTH = 6;

    struct Split {
        address router;    
        uint percentage;
        address[] path;
        uint expectedOutput; // Added for better optimization
        uint priceImpact;   // Added to track price impact
    }

    struct TradeRoute {
        address inputToken;
        address outputToken;
        uint hops;            
        Split[][] splitRoutes;
        uint totalExpectedOutput;
        uint routeScore; // Added for route ranking
        uint gasEstimate; // Added for gas optimization
    }

    // Genetic algorithm chromosome for route optimization
    struct RouteChromosome {
        address[] intermediateTokens;
        uint[] hopAllocations;
        uint fitness;
    }

    // Linear programming variables for split optimization
    struct LPVariable {
        address router;
        uint coefficient;
        uint upperBound;
        uint lowerBound;
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
    event RouteOptimized(address indexed inputToken, address indexed outputToken, uint hops, uint expectedOutput);

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
            if (!whitelistedTokens[tokens[i]]) {
                whitelistedTokens[tokens[i]] = true;
                whitelistedTokenArray.push(tokens[i]);
                emit TokenWhitelisted(tokens[i]);
            }
        }
    }

    function removeTokenFromWhitelist(address token) external onlyOwner {
        require(whitelistedTokens[token], "Token not whitelisted");
        whitelistedTokens[token] = false;
        
        // Remove from array
        for (uint i = 0; i < whitelistedTokenArray.length; i++) {
            if (whitelistedTokenArray[i] == token) {
                whitelistedTokenArray[i] = whitelistedTokenArray[whitelistedTokenArray.length - 1];
                whitelistedTokenArray.pop();
                break;
            }
        }
        emit TokenRemovedFromWhitelist(token);
    }

    function getRouters() external view returns (address[] memory) {
        return routers;
    }

    function isWhitelisted(address token) public view returns (bool) {
        return whitelistedTokens[token];
    }

    function setCacheTimeout(uint _timeout) external onlyOwner {
        require(_timeout >= 60 && _timeout <= 3600, "Invalid timeout");
        cacheTimeout = _timeout;
    }

    // Advanced route finding with multiple optimization algorithms
    function findBestRoute(
        uint amountIn,
        address inputToken,
        address outputToken
    ) external view returns (TradeRoute memory route, uint expectedOut) {
        require(amountIn > 0, "Amount must be greater than 0");
        require(inputToken != address(0) && outputToken != address(0), "Invalid token addresses");
        require(inputToken != outputToken, "Input and output tokens must be different");
        require(routers.length > 0, "No routers configured");

        // Check cache first
        bytes32 cacheKey = keccak256(abi.encodePacked(amountIn, inputToken, outputToken, block.timestamp / cacheTimeout));
        uint cachedOutput = routeCache[cacheKey];

        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        expectedOut = 0;

        // Algorithm 1: Greedy Algorithm (fast, baseline)
        (uint greedyOutput, TradeRoute memory greedyRoute) = findRouteGreedy(amountIn, inputToken, outputToken);
        if (greedyOutput > expectedOut) {
            expectedOut = greedyOutput;
            bestRoute = greedyRoute;
        }

        // Algorithm 2: Dynamic Programming with optimal hop allocation
        (uint dpOutput, TradeRoute memory dpRoute) = findRouteDynamicProgramming(amountIn, inputToken, outputToken);
        if (dpOutput > expectedOut) {
            expectedOut = dpOutput;
            bestRoute = dpRoute;
        }

        // Algorithm 3: Genetic Algorithm (for complex scenarios)
        if (amountIn > 1000000) { // Only for larger amounts due to gas cost
            (uint geneticOutput, TradeRoute memory geneticRoute) = findRouteGenetic(amountIn, inputToken, outputToken);
            if (geneticOutput > expectedOut) {
                expectedOut = geneticOutput;
                bestRoute = geneticRoute;
            }
        }

        // Algorithm 4: Linear Programming approximation for split optimization
        if (bestRoute.hops > 0) {
            (uint lpOutput, TradeRoute memory lpRoute) = optimizeRouteSplitsLP(amountIn, bestRoute);
            if (lpOutput > expectedOut) {
                expectedOut = lpOutput;
                bestRoute = lpRoute;
            }
        }

        // Algorithm 5: Brute Force Simulation (for small search spaces)
        if (getAllWhitelistedTokens().length <= 10) {
            (uint bruteOutput, TradeRoute memory bruteRoute) = findRouteBruteForce(amountIn, inputToken, outputToken);
            if (bruteOutput > expectedOut) {
                expectedOut = bruteOutput;
                bestRoute = bruteRoute;
            }
        }

        // Algorithm 6: Smart Order Routing with price impact analysis
        (uint sorOutput, TradeRoute memory sorRoute) = smartOrderRouting(amountIn, inputToken, outputToken, bestRoute);
        if (sorOutput > expectedOut) {
            expectedOut = sorOutput;
            bestRoute = sorRoute;
        }

        // Algorithm 7: Triangular & Cyclic Arbitrage Enhancement
        (uint arbOutput, TradeRoute memory arbRoute) = enhanceRouteWithArbitrage(amountIn, inputToken, outputToken, bestRoute);
        if (arbOutput > expectedOut) {
            expectedOut = arbOutput;
            bestRoute = arbRoute;
        }

        // Finalize route
        if (expectedOut > 0 && bestRoute.hops > 0) {
            bestRoute.totalExpectedOutput = expectedOut;
            bestRoute.routeScore = calculateRouteScore(bestRoute, amountIn);
            route = bestRoute;

            emit RouteOptimized(inputToken, outputToken, bestRoute.hops, expectedOut);
        } else {
            route = TradeRoute({
                inputToken: inputToken,
                outputToken: outputToken,
                hops: 0,
                splitRoutes: new Split[][](0),
                totalExpectedOutput: 0,
                routeScore: 0,
                gasEstimate: 0
            });
            expectedOut = 0;
        }
    }

    // Algorithm 1: Greedy Algorithm - Always choose the best immediate hop
    function findRouteGreedy(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        uint bestOutput = 0;

        // Try different hop counts dynamically
        for (uint targetHops = 1; targetHops <= MAX_HOPS; targetHops++) {
            (uint hopOutput, TradeRoute memory hopRoute) = findGreedyRouteWithHops(
                amountIn, 
                inputToken, 
                outputToken, 
                targetHops
            );

            if (hopOutput > bestOutput) {
                bestOutput = hopOutput;
                bestRoute = hopRoute;
            }

            // Early termination if we found a very good route
            if (hopOutput > amountIn * 2) break;
        }

        return (bestOutput, bestRoute);
    }

    function findGreedyRouteWithHops(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint targetHops
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (targetHops == 0) return (0, route);

        TradeRoute memory greedyRoute;
        greedyRoute.inputToken = inputToken;
        greedyRoute.outputToken = outputToken;
        greedyRoute.hops = targetHops;
        greedyRoute.splitRoutes = new Split[][](targetHops);

        address currentToken = inputToken;
        uint currentAmount = amountIn;
        address[] memory usedTokens = new address[](targetHops + 1);
        usedTokens[0] = inputToken;

        for (uint hop = 0; hop < targetHops; hop++) {
            address nextToken;
            if (hop == targetHops - 1) {
                nextToken = outputToken;
            } else {
                // Greedy selection: choose the intermediate token with best liquidity
                nextToken = selectBestIntermediateToken(currentToken, outputToken, usedTokens, hop + 1);
                if (nextToken == address(0)) return (0, route);
                usedTokens[hop + 1] = nextToken;
            }

            (uint hopOutput, Split[] memory hopSplits) = findBestSplitForHop(
                currentAmount,
                currentToken,
                nextToken,
                usedTokens
            );

            if (hopOutput == 0 || hopSplits.length == 0) return (0, route);

            greedyRoute.splitRoutes[hop] = hopSplits;
            currentAmount = hopOutput;
            currentToken = nextToken;
        }

        return (currentAmount, greedyRoute);
    }

    // Algorithm 2: Dynamic Programming with memoization (fixed)
    function findRouteDynamicProgramming(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        TradeRoute memory bestRoute;
        bestRoute.inputToken = inputToken;
        bestRoute.outputToken = outputToken;
        uint bestOutput = 0;

        // Dynamic programming: try all possible hop allocations
        for (uint hops = 1; hops <= MAX_HOPS; hops++) {
            (uint dpOutput, TradeRoute memory dpRoute) = dpFindRoute(
                amountIn,
                inputToken,
                outputToken,
                hops
            );

            if (dpOutput > bestOutput) {
                bestOutput = dpOutput;
                bestRoute = dpRoute;
            }
        }

        return (bestOutput, bestRoute);
    }

    function dpFindRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        uint hops
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        bytes32 key = keccak256(abi.encodePacked(amountIn, inputToken, outputToken, hops));
        
        // Check memoization in storage
        if (dpMemoization[key] != 0) {
            return (dpMemoization[key], route);
        }

        if (hops == 1) {
            (uint directOutput, Split[] memory directSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                outputToken,
                new address[](0)
            );

            if (directOutput > 0) {
                route.inputToken = inputToken;
                route.outputToken = outputToken;
                route.hops = 1;
                route.splitRoutes = new Split[][](1);
                route.splitRoutes[0] = directSplits;
                return (directOutput, route);
            }
        } else {
            // Try all possible intermediate tokens
            address[] memory intermediates = getAllWhitelistedTokens();
            uint bestOutput = 0;
            TradeRoute memory bestRoute;

            for (uint i = 0; i < intermediates.length; i++) {
                if (intermediates[i] == inputToken || intermediates[i] == outputToken) continue;

                (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                    amountIn,
                    inputToken,
                    intermediates[i],
                    new address[](0)
                );

                if (firstHopOutput == 0) continue;

                (uint remainingOutput, TradeRoute memory remainingRoute) = dpFindRoute(
                    firstHopOutput,
                    intermediates[i],
                    outputToken,
                    hops - 1
                );

                if (remainingOutput > bestOutput) {
                    bestOutput = remainingOutput;
                    bestRoute = remainingRoute;

                    // Prepend first hop to the route
                    TradeRoute memory newRoute;
                    newRoute.inputToken = inputToken;
                    newRoute.outputToken = outputToken;
                    newRoute.hops = hops;
                    newRoute.splitRoutes = new Split[][](hops);
                    newRoute.splitRoutes[0] = firstHopSplits;

                    for (uint j = 0; j < hops - 1; j++) {
                        newRoute.splitRoutes[j + 1] = remainingRoute.splitRoutes[j];
                    }
                    bestRoute = newRoute;
                }
            }

            if (bestOutput > 0) {
                return (bestOutput, bestRoute);
            }
        }

        return (0, route);
    }

    // Algorithm 3: Genetic Algorithm for complex optimization
    function findRouteGenetic(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        // Initialize population
        RouteChromosome[] memory population = new RouteChromosome[](GENETIC_POPULATION_SIZE);
        address[] memory tokenPool = getAllWhitelistedTokens();

        // Create initial population
        for (uint i = 0; i < GENETIC_POPULATION_SIZE; i++) {
            population[i] = createRandomChromosome(tokenPool, inputToken, outputToken);
            population[i].fitness = evaluateChromosomeFitness(population[i], amountIn, inputToken, outputToken);
        }

        // Evolution loop
        for (uint generation = 0; generation < GENETIC_GENERATIONS; generation++) {
            // Selection, crossover, and mutation
            population = evolvePopulation(population, amountIn, inputToken, outputToken, tokenPool);
        }

        // Find best chromosome
        RouteChromosome memory best = population[0];
        for (uint i = 1; i < GENETIC_POPULATION_SIZE; i++) {
            if (population[i].fitness > best.fitness) {
                best = population[i];
            }
        }

        // Convert best chromosome to route
        if (best.fitness > 0) {
            (expectedOut, route) = chromosomeToRoute(best, amountIn, inputToken, outputToken);
        }

        return (expectedOut, route);
    }

    function createRandomChromosome(
        address[] memory tokenPool,
        address inputToken,
        address outputToken
    ) internal view returns (RouteChromosome memory chromosome) {
        uint hops = (uint(keccak256(abi.encodePacked(block.timestamp, inputToken))) % MAX_HOPS) + 1;
        chromosome.intermediateTokens = new address[](hops > 2 ? hops - 2 : 0);
        chromosome.hopAllocations = new uint[](hops);

        // Random intermediate tokens
        for (uint i = 0; i < chromosome.intermediateTokens.length; i++) {
            uint randomIndex = uint(keccak256(abi.encodePacked(block.timestamp, i))) % tokenPool.length;
            chromosome.intermediateTokens[i] = tokenPool[randomIndex];
        }

        // Random hop allocations (percentages)
        uint remaining = 10000;
        for (uint i = 0; i < hops - 1; i++) {
            chromosome.hopAllocations[i] = (uint(keccak256(abi.encodePacked(block.timestamp, i + 100))) % (remaining / 2)) + 100;
            remaining -= chromosome.hopAllocations[i];
        }
        chromosome.hopAllocations[hops - 1] = remaining;

        return chromosome;
    }

    function evaluateChromosomeFitness(
        RouteChromosome memory chromosome,
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint fitness) {
        // Simplified fitness evaluation - convert chromosome to route and test
        (uint output,) = chromosomeToRoute(chromosome, amountIn, inputToken, outputToken);
        return output;
    }

    function evolvePopulation(
        RouteChromosome[] memory population,
        uint amountIn,
        address inputToken,
        address outputToken,
        address[] memory tokenPool
    ) internal view returns (RouteChromosome[] memory newPopulation) {
        newPopulation = new RouteChromosome[](GENETIC_POPULATION_SIZE);

        // Elitism: keep best 20%
        uint eliteCount = GENETIC_POPULATION_SIZE / 5;
        sortPopulationByFitness(population);

        for (uint i = 0; i < eliteCount; i++) {
            newPopulation[i] = population[i];
        }

        // Generate rest through crossover and mutation
        for (uint i = eliteCount; i < GENETIC_POPULATION_SIZE; i++) {
            RouteChromosome memory parent1 = tournamentSelection(population);
            RouteChromosome memory parent2 = tournamentSelection(population);
            RouteChromosome memory child = crossover(parent1, parent2);
            child = mutate(child, tokenPool);
            child.fitness = evaluateChromosomeFitness(child, amountIn, inputToken, outputToken);
            newPopulation[i] = child;
        }

        return newPopulation;
    }

    function sortPopulationByFitness(RouteChromosome[] memory population) internal pure {
        // Simple bubble sort for demonstration
        for (uint i = 0; i < population.length; i++) {
            for (uint j = i + 1; j < population.length; j++) {
                if (population[j].fitness > population[i].fitness) {
                    RouteChromosome memory temp = population[i];
                    population[i] = population[j];
                    population[j] = temp;
                }
            }
        }
    }

    function tournamentSelection(RouteChromosome[] memory population) internal view returns (RouteChromosome memory) {
        uint tournamentSize = 3;
        RouteChromosome memory best = population[0];

        for (uint i = 0; i < tournamentSize; i++) {
            uint randomIndex = uint(keccak256(abi.encodePacked(block.timestamp, i))) % population.length;
            if (population[randomIndex].fitness > best.fitness) {
                best = population[randomIndex];
            }
        }

        return best;
    }

    function crossover(
        RouteChromosome memory parent1,
        RouteChromosome memory parent2
    ) internal pure returns (RouteChromosome memory child) {
        // Single-point crossover
        uint crossoverPoint = parent1.intermediateTokens.length / 2;

        child.intermediateTokens = new address[](parent1.intermediateTokens.length);
        child.hopAllocations = new uint[](parent1.hopAllocations.length);

        for (uint i = 0; i < parent1.intermediateTokens.length; i++) {
            if (i < crossoverPoint) {
                child.intermediateTokens[i] = parent1.intermediateTokens[i];
            } else {
                child.intermediateTokens[i] = parent2.intermediateTokens[i];
            }
        }

        for (uint i = 0; i < parent1.hopAllocations.length; i++) {
            if (i < crossoverPoint) {
                child.hopAllocations[i] = parent1.hopAllocations[i];
            } else {
                child.hopAllocations[i] = parent2.hopAllocations[i];
            }
        }

        return child;
    }

    function mutate(
        RouteChromosome memory chromosome,
        address[] memory tokenPool
    ) internal view returns (RouteChromosome memory) {
        uint mutationRate = 100; // 1% mutation rate

        for (uint i = 0; i < chromosome.intermediateTokens.length; i++) {
            if (uint(keccak256(abi.encodePacked(block.timestamp, i))) % 10000 < mutationRate) {
                uint randomIndex = uint(keccak256(abi.encodePacked(block.timestamp, i + 1000))) % tokenPool.length;
                chromosome.intermediateTokens[i] = tokenPool[randomIndex];
            }
        }

        return chromosome;
    }

    function chromosomeToRoute(
        RouteChromosome memory chromosome,
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        uint hops = chromosome.hopAllocations.length;
        route.inputToken = inputToken;
        route.outputToken = outputToken;
        route.hops = hops;
        route.splitRoutes = new Split[][](hops);

        address currentToken = inputToken;
        uint currentAmount = amountIn;

        for (uint hop = 0; hop < hops; hop++) {
            address nextToken;
            if (hop == hops - 1) {
                nextToken = outputToken;
            } else {
                nextToken = chromosome.intermediateTokens[hop];
            }

            (uint hopOutput, Split[] memory hopSplits) = findBestSplitForHop(
                currentAmount,
                currentToken,
                nextToken,
                new address[](0)
            );

            if (hopOutput == 0) return (0, route);

            route.splitRoutes[hop] = hopSplits;
            currentAmount = hopOutput;
            currentToken = nextToken;
        }

        return (currentAmount, route);
    }

    // Algorithm 4: Linear Programming for split optimization
    function optimizeRouteSplitsLP(
        uint amountIn,
        TradeRoute memory route
    ) internal view returns (uint expectedOut, TradeRoute memory optimizedRoute) {
        optimizedRoute = route;

        // Apply LP optimization to each hop
        for (uint hop = 0; hop < route.hops; hop++) {
            Split[] memory originalSplits = route.splitRoutes[hop];
            if (originalSplits.length <= 1) continue;

            // Create LP variables for this hop
            LPVariable[] memory variables = new LPVariable[](originalSplits.length);
            for (uint i = 0; i < originalSplits.length; i++) {
                variables[i] = LPVariable({
                    router: originalSplits[i].router,
                    coefficient: originalSplits[i].expectedOutput,
                    upperBound: 10000,
                    lowerBound: 0
                });
            }

            // Solve LP problem using simplex approximation
            uint[] memory optimalPercentages = solveLPSimplex(variables, amountIn);

            // Update splits with optimal percentages
            uint validSplits = 0;
            for (uint i = 0; i < optimalPercentages.length; i++) {
                if (optimalPercentages[i] > 0) validSplits++;
            }

            Split[] memory newSplits = new Split[](validSplits);
            uint splitIndex = 0;
            for (uint i = 0; i < optimalPercentages.length; i++) {
                if (optimalPercentages[i] > 0) {
                    newSplits[splitIndex] = originalSplits[i];
                    newSplits[splitIndex].percentage = optimalPercentages[i];
                    splitIndex++;
                }
            }

            optimizedRoute.splitRoutes[hop] = newSplits;
        }

        // Calculate total expected output
        expectedOut = simulateRoute(amountIn, optimizedRoute);
        return (expectedOut, optimizedRoute);
    }

    function solveLPSimplex(
        LPVariable[] memory variables,
        uint totalAmount
    ) internal pure returns (uint[] memory solution) {
        solution = new uint[](variables.length);

        // Simplified linear programming solver
        // Maximize: sum(coefficient_i * x_i)
        // Subject to: sum(x_i) = 10000, 0 <= x_i <= upperBound_i

        uint totalCoefficient = 0;
        for (uint i = 0; i < variables.length; i++) {
            totalCoefficient += variables[i].coefficient;
        }

        if (totalCoefficient == 0) {
            // Equal distribution fallback
            uint equalShare = 10000 / variables.length;
            for (uint i = 0; i < variables.length; i++) {
                solution[i] = equalShare;
            }
            return solution;
        }

        // Proportional allocation based on coefficients
        uint allocated = 0;
        for (uint i = 0; i < variables.length; i++) {
            if (i == variables.length - 1) {
                solution[i] = 10000 - allocated;
            } else {
                solution[i] = (variables[i].coefficient * 10000) / totalCoefficient;
                allocated += solution[i];
            }
        }

        return solution;
    }

    // Algorithm 5: Brute Force Simulation
    function findRouteBruteForce(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        address[] memory tokens = getAllWhitelistedTokens();
        uint bestOutput = 0;
        TradeRoute memory bestRoute;

        uint combinations = 0;

        // Try all possible combinations up to BRUTE_FORCE_LIMIT
        for (uint hops = 1; hops <= MAX_HOPS && combinations < BRUTE_FORCE_LIMIT; hops++) {
            (uint hopOutput, TradeRoute memory hopRoute, uint hopCombinations) = bruteForceHops(
                amountIn,
                inputToken,
                outputToken,
                tokens,
                hops,
                BRUTE_FORCE_LIMIT - combinations
            );

            combinations += hopCombinations;

            if (hopOutput > bestOutput) {
                bestOutput = hopOutput;
                bestRoute = hopRoute;
            }

            if (combinations >= BRUTE_FORCE_LIMIT) break;
        }

        return (bestOutput, bestRoute);
    }

    function bruteForceHops(
        uint amountIn,
        address inputToken,
        address outputToken,
        address[] memory tokens,
        uint hops,
        uint remainingLimit
    ) internal view returns (uint bestOutput, TradeRoute memory bestRoute, uint combinations) {
        if (hops == 1) {
            (uint directOutput, Split[] memory directSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                outputToken,
                new address[](0)
            );

            if (directOutput > 0) {
                bestRoute.inputToken = inputToken;
                bestRoute.outputToken = outputToken;
                bestRoute.hops = 1;
                bestRoute.splitRoutes = new Split[][](1);
                bestRoute.splitRoutes[0] = directSplits;
                bestOutput = directOutput;
            }
            return (bestOutput, bestRoute, 1);
        }

        combinations = 0;
        bestOutput = 0;

        // Try all intermediate tokens
        for (uint i = 0; i < tokens.length && combinations < remainingLimit; i++) {
            if (tokens[i] == inputToken || tokens[i] == outputToken) continue;

            (uint firstHopOutput, Split[] memory firstHopSplits) = findBestSplitForHop(
                amountIn,
                inputToken,
                tokens[i],
                new address[](0)
            );

            if (firstHopOutput == 0) continue;

            (uint remainingOutput, TradeRoute memory remainingRoute, uint subCombinations) = bruteForceHops(
                firstHopOutput,
                tokens[i],
                outputToken,
                tokens,
                hops - 1,
                remainingLimit - combinations - 1
            );

            combinations += subCombinations + 1;

            if (remainingOutput > bestOutput) {
                bestOutput = remainingOutput;

                bestRoute.inputToken = inputToken;
                bestRoute.outputToken = outputToken;
                bestRoute.hops = hops;
                bestRoute.splitRoutes = new Split[][](hops);
                bestRoute.splitRoutes[0] = firstHopSplits;

                for (uint j = 0; j < hops - 1; j++) {
                    bestRoute.splitRoutes[j + 1] = remainingRoute.splitRoutes[j];
                }
            }

            if (combinations >= remainingLimit) break;
        }

        return (bestOutput, bestRoute, combinations);
    }

    // Algorithm 6: Smart Order Routing with price impact analysis
    function smartOrderRouting(
        uint amountIn,
        address inputToken,
        address outputToken,
        TradeRoute memory currentBestRoute
    ) internal view returns (uint expectedOut, TradeRoute memory route) {
        if (currentBestRoute.hops == 0) {
            return (0, currentBestRoute);
        }

        // Analyze price impact for current route
        uint totalPriceImpact = calculateRoutePriceImpact(amountIn, currentBestRoute);

        // If price impact is high, try to optimize
        if (totalPriceImpact > 500) { // >5% impact
            return optimizeHighImpactRoute(amountIn, inputToken, outputToken, currentBestRoute);
        }

        // For low impact routes, try to find better split distributions
        return optimizeLowImpactRoute(amountIn, currentBestRoute);
    }

    function optimizeHighImpactRoute(
        uint amountIn,
        address inputToken,
        address outputToken,
        TradeRoute memory route
    ) internal view returns (uint expectedOut, TradeRoute memory optimizedRoute) {
        // Strategy: Add more hops to reduce price impact per hop
        if (route.hops >= MAX_HOPS) {
            return (route.totalExpectedOutput, route);
        }

        // Try adding one more hop
        TradeRoute memory extendedRoute = addIntermediateHop(amountIn, route);
        uint extendedOutput = simulateRoute(amountIn, extendedRoute);

        if (extendedOutput > route.totalExpectedOutput) {
            return (extendedOutput, extendedRoute);
        }

        return (route.totalExpectedOutput, route);
    }

    function optimizeLowImpactRoute(
        uint amountIn,
        TradeRoute memory route
    ) internal view returns (uint expectedOut, TradeRoute memory optimizedRoute) {
        // Strategy: Optimize split percentages for maximum output
        optimizedRoute = route;

        for (uint hop = 0; hop < route.hops; hop++) {
            Split[] memory hopSplits = route.splitRoutes[hop];
            if (hopSplits.length > 1) {
                // Apply advanced split optimization
                Split[] memory optimizedSplits = optimizeSplitPercentagesAdvanced(
                    amountIn,
                    hopSplits
                );
                optimizedRoute.splitRoutes[hop] = optimizedSplits;
            }
        }

        expectedOut = simulateRoute(amountIn, optimizedRoute);
        return (expectedOut, optimizedRoute);
    }

    // Algorithm 7: Arbitrage-Enhanced Routing
    function enhanceRouteWithArbitrage(
        uint amountIn,
        address inputToken,
        address outputToken,
        TradeRoute memory baseRoute
    ) internal view returns (uint expectedOut, TradeRoute memory enhancedRoute) {
        if (baseRoute.hops == 0) {
            return (0, baseRoute);
        }

        // Detect arbitrage opportunities that can enhance the route
        ArbitrageRoute memory arbRoute = detectArbitrageOpportunities(amountIn, inputToken, outputToken);
        
        if (arbRoute.totalProfit == 0) {
            return (baseRoute.totalExpectedOutput, baseRoute);
        }

        // Integrate arbitrage into the base route
        enhancedRoute = integrateArbitrageIntoRoute(amountIn, baseRoute, arbRoute);
        expectedOut = calculateArbitrageEnhancedOutput(amountIn, enhancedRoute, arbRoute);

        // Only return enhanced route if it's significantly better
        if (expectedOut > baseRoute.totalExpectedOutput) {
            return (expectedOut, enhancedRoute);
        }

        return (baseRoute.totalExpectedOutput, baseRoute);
    }

    function detectArbitrageOpportunities(
        uint amountIn,
        address inputToken,
        address outputToken
    ) internal view returns (ArbitrageRoute memory arbRoute) {
        address[] memory tokens = getAllWhitelistedTokens();
        
        arbRoute.opportunities = new ArbitrageOpportunity[](MAX_ARBITRAGE_CYCLES);
        uint opportunityCount = 0;

        // Detect triangular arbitrage (3-token cycles)
        for (uint i = 0; i < tokens.length && opportunityCount < MAX_ARBITRAGE_CYCLES; i++) {
            if (tokens[i] == inputToken || tokens[i] == outputToken) continue;

            ArbitrageOpportunity memory triOpp = detectTriangularArbitrage(
                inputToken, 
                tokens[i], 
                outputToken, 
                amountIn / 10 // Use portion for arbitrage detection
            );

            if (triOpp.profit > 0 && triOpp.profitability >= MIN_ARBITRAGE_PROFIT_BPS) {
                arbRoute.opportunities[opportunityCount] = triOpp;
                arbRoute.totalProfit += triOpp.profit;
                opportunityCount++;
            }
        }

        // Detect cyclic arbitrage (4-6 token cycles)
        if (opportunityCount < MAX_ARBITRAGE_CYCLES) {
            ArbitrageOpportunity[] memory cyclicOpps = detectCyclicArbitrage(
                inputToken, 
                outputToken, 
                tokens, 
                amountIn / 20 // Smaller portion for complex cycles
            );

            for (uint i = 0; i < cyclicOpps.length && opportunityCount < MAX_ARBITRAGE_CYCLES; i++) {
                if (cyclicOpps[i].profit > 0 && cyclicOpps[i].profitability >= MIN_ARBITRAGE_PROFIT_BPS) {
                    arbRoute.opportunities[opportunityCount] = cyclicOpps[i];
                    arbRoute.totalProfit += cyclicOpps[i].profit;
                    opportunityCount++;
                }
            }
        }

        // Resize array to actual count
        ArbitrageOpportunity[] memory finalOpps = new ArbitrageOpportunity[](opportunityCount);
        for (uint i = 0; i < opportunityCount; i++) {
            finalOpps[i] = arbRoute.opportunities[i];
        }
        arbRoute.opportunities = finalOpps;

        return arbRoute;
    }

    function detectTriangularArbitrage(
        address tokenA,
        address tokenB,
        address tokenC,
        uint testAmount
    ) internal view returns (ArbitrageOpportunity memory opportunity) {
        if (testAmount == 0 || tokenA == tokenB || tokenB == tokenC || tokenA == tokenC) {
            return opportunity;
        }

        // Test cycle: A -> B -> C -> A
        address[] memory cycle = new address[](4);
        cycle[0] = tokenA;
        cycle[1] = tokenB;
        cycle[2] = tokenC;
        cycle[3] = tokenA;

        uint[] memory amounts = new uint[](4);
        amounts[0] = testAmount;

        // A -> B
        amounts[1] = getBestOutputForPair(amounts[0], tokenA, tokenB);
        if (amounts[1] == 0) return opportunity;

        // B -> C
        amounts[2] = getBestOutputForPair(amounts[1], tokenB, tokenC);
        if (amounts[2] == 0) return opportunity;

        // C -> A
        amounts[3] = getBestOutputForPair(amounts[2], tokenC, tokenA);
        if (amounts[3] == 0) return opportunity;

        // Calculate profit
        if (amounts[3] > amounts[0]) {
            uint profit = amounts[3] - amounts[0];
            uint profitability = (profit * 10000) / amounts[0];

            opportunity = ArbitrageOpportunity({
                cycle: cycle,
                amounts: amounts,
                profit: profit,
                profitability: profitability,
                isTriangular: true
            });
        }

        return opportunity;
    }

    function detectCyclicArbitrage(
        address startToken,
        address endToken,
        address[] memory availableTokens,
        uint testAmount
    ) internal view returns (ArbitrageOpportunity[] memory opportunities) {
        uint maxOpps = 3; // Limit cyclic opportunities
        opportunities = new ArbitrageOpportunity[](maxOpps);
        uint oppCount = 0;

        // Generate cycles of length 4-6
        for (uint cycleLength = 4; cycleLength <= MAX_CYCLE_LENGTH && oppCount < maxOpps; cycleLength++) {
            ArbitrageOpportunity memory cyclicOpp = findBestCyclicArbitrage(
                startToken,
                endToken,
                availableTokens,
                testAmount,
                cycleLength
            );

            if (cyclicOpp.profit > 0) {
                opportunities[oppCount] = cyclicOpp;
                oppCount++;
            }
        }

        // Resize to actual count
        ArbitrageOpportunity[] memory result = new ArbitrageOpportunity[](oppCount);
        for (uint i = 0; i < oppCount; i++) {
            result[i] = opportunities[i];
        }

        return result;
    }

    function findBestCyclicArbitrage(
        address startToken,
        address endToken,
        address[] memory availableTokens,
        uint testAmount,
        uint cycleLength
    ) internal view returns (ArbitrageOpportunity memory bestOpportunity) {
        if (cycleLength < 4 || availableTokens.length < cycleLength - 2) {
            return bestOpportunity;
        }

        uint bestProfit = 0;

        // Try different combinations of intermediate tokens
        uint[] memory indices = new uint[](cycleLength - 2);
        
        // Simple combinatorial approach (limited for gas efficiency)
        for (uint i = 0; i < availableTokens.length && i < 3; i++) {
            if (availableTokens[i] == startToken || availableTokens[i] == endToken) continue;
            
            for (uint j = i + 1; j < availableTokens.length && j < 6; j++) {
                if (availableTokens[j] == startToken || availableTokens[j] == endToken || availableTokens[j] == availableTokens[i]) continue;

                address[] memory cycle = new address[](cycleLength + 1);
                cycle[0] = startToken;
                cycle[1] = availableTokens[i];
                cycle[2] = availableTokens[j];
                
                if (cycleLength > 4) {
                    for (uint k = j + 1; k < availableTokens.length && k < 9; k++) {
                        if (availableTokens[k] == startToken || availableTokens[k] == endToken || 
                            availableTokens[k] == availableTokens[i] || availableTokens[k] == availableTokens[j]) continue;
                        
                        cycle[3] = availableTokens[k];
                        if (cycleLength > 5) {
                            cycle[4] = endToken;
                            cycle[5] = startToken;
                        } else {
                            cycle[3] = endToken;
                            cycle[4] = startToken;
                        }
                        break;
                    }
                } else {
                    cycle[3] = endToken;
                    cycle[4] = startToken;
                }

                ArbitrageOpportunity memory opportunity = testCycleArbitrage(cycle, testAmount);
                if (opportunity.profit > bestProfit) {
                    bestProfit = opportunity.profit;
                    bestOpportunity = opportunity;
                }
            }
        }

        return bestOpportunity;
    }

    function testCycleArbitrage(
        address[] memory cycle,
        uint testAmount
    ) internal view returns (ArbitrageOpportunity memory opportunity) {
        if (cycle.length < 4 || testAmount == 0) return opportunity;

        uint[] memory amounts = new uint[](cycle.length);
        amounts[0] = testAmount;

        // Test the cycle
        for (uint i = 0; i < cycle.length - 1; i++) {
            amounts[i + 1] = getBestOutputForPair(amounts[i], cycle[i], cycle[i + 1]);
            if (amounts[i + 1] == 0) return opportunity; // Cycle broken
        }

        // Check if profitable
        if (amounts[amounts.length - 1] > testAmount) {
            uint profit = amounts[amounts.length - 1] - testAmount;
            uint profitability = (profit * 10000) / testAmount;

            opportunity = ArbitrageOpportunity({
                cycle: cycle,
                amounts: amounts,
                profit: profit,
                profitability: profitability,
                isTriangular: false
            });
        }

        return opportunity;
    }

    function getBestOutputForPair(
        uint amountIn,
        address tokenIn,
        address tokenOut
    ) internal view returns (uint bestOutput) {
        if (amountIn == 0 || tokenIn == tokenOut) return 0;

        address[] memory path = getPath(tokenIn, tokenOut);
        if (path.length < 2) return 0;

        for (uint i = 0; i < routers.length; i++) {
            if (routers[i] == address(0)) continue;

            try IUniswapV2Router02(routers[i]).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                if (amounts.length > 1 && amounts[amounts.length - 1] > bestOutput) {
                    bestOutput = amounts[amounts.length - 1];
                }
            } catch {}
        }

        return bestOutput;
    }

    function integrateArbitrageIntoRoute(
        uint amountIn,
        TradeRoute memory baseRoute,
        ArbitrageRoute memory arbRoute
    ) internal view returns (TradeRoute memory enhancedRoute) {
        enhancedRoute = baseRoute;

        if (arbRoute.opportunities.length == 0) {
            return enhancedRoute;
        }

        // Strategy: Use arbitrage opportunities to enhance intermediate hops
        for (uint oppIndex = 0; oppIndex < arbRoute.opportunities.length; oppIndex++) {
            ArbitrageOpportunity memory opp = arbRoute.opportunities[oppIndex];
            
            // Find best integration point in the route
            uint bestHop = findBestArbitrageIntegrationPoint(enhancedRoute, opp);
            
            if (bestHop < enhancedRoute.hops) {
                enhancedRoute = insertArbitrageIntoHop(enhancedRoute, opp, bestHop, amountIn);
            }
        }

        return enhancedRoute;
    }

    function findBestArbitrageIntegrationPoint(
        TradeRoute memory route,
        ArbitrageOpportunity memory opportunity
    ) internal pure returns (uint bestHop) {
        bestHop = route.hops; // Default: no integration

        for (uint hop = 0; hop < route.hops; hop++) {
            Split[] memory hopSplits = route.splitRoutes[hop];
            
            // Check if any split in this hop uses tokens from the arbitrage cycle
            for (uint splitIndex = 0; splitIndex < hopSplits.length; splitIndex++) {
                address[] memory splitPath = hopSplits[splitIndex].path;
                
                for (uint pathIndex = 0; pathIndex < splitPath.length; pathIndex++) {
                    for (uint cycleIndex = 0; cycleIndex < opportunity.cycle.length; cycleIndex++) {
                        if (splitPath[pathIndex] == opportunity.cycle[cycleIndex]) {
                            return hop; // Found integration point
                        }
                    }
                }
            }
        }

        return bestHop;
    }

    function insertArbitrageIntoHop(
        TradeRoute memory route,
        ArbitrageOpportunity memory opportunity,
        uint targetHop,
        uint amountIn
    ) internal view returns (TradeRoute memory enhancedRoute) {
        enhancedRoute = route;

        if (targetHop >= route.hops || opportunity.cycle.length < 3) {
            return enhancedRoute;
        }

        // Create arbitrage-enhanced split for the target hop
        Split[] memory originalSplits = route.splitRoutes[targetHop];
        Split[] memory enhancedSplits = new Split[](originalSplits.length + 1);

        // Copy original splits with reduced percentages
        uint totalReduction = 2000; // 20% for arbitrage
        uint reductionPerSplit = totalReduction / originalSplits.length;

        for (uint i = 0; i < originalSplits.length; i++) {
            enhancedSplits[i] = originalSplits[i];
            if (enhancedSplits[i].percentage > reductionPerSplit) {
                enhancedSplits[i].percentage -= reductionPerSplit;
            }
        }

        // Add arbitrage split
        enhancedSplits[originalSplits.length] = createArbitrageSplit(
            opportunity, 
            totalReduction,
            targetHop,
            route,
            amountIn
        );

        enhancedRoute.splitRoutes[targetHop] = enhancedSplits;
        return enhancedRoute;
    }

    function createArbitrageSplit(
        ArbitrageOpportunity memory opportunity,
        uint percentage,
        uint hopIndex,
        TradeRoute memory route,
        uint amountIn
    ) internal view returns (Split memory arbitrageSplit) {
        // Use the first available router for arbitrage
        address arbRouter = routers.length > 0 ? routers[0] : address(0);
        
        // Create path from arbitrage cycle that fits the hop
        address[] memory hopPath = new address[](2);
        if (hopIndex < route.hops) {
            Split[] memory hopSplits = route.splitRoutes[hopIndex];
            if (hopSplits.length > 0) {
                hopPath[0] = hopSplits[0].path[0];
                hopPath[1] = hopSplits[0].path[hopSplits[0].path.length - 1];
            }
        }

        // Estimate output using arbitrage profit
        uint estimatedOutput = (amountIn * percentage / 10000) + (opportunity.profit * percentage / 10000);

        arbitrageSplit = Split({
            router: arbRouter,
            percentage: percentage,
            path: hopPath,
            expectedOutput: estimatedOutput,
            priceImpact: 0 // Arbitrage typically has minimal price impact
        });

        return arbitrageSplit;
    }

    function calculateArbitrageEnhancedOutput(
        uint amountIn,
        TradeRoute memory route,
        ArbitrageRoute memory arbRoute
    ) internal view returns (uint enhancedOutput) {
        // Calculate base route output
        uint baseOutput = simulateRoute(amountIn, route);
        
        // Add arbitrage profits (scaled appropriately)
        uint arbitrageBonus = 0;
        for (uint i = 0; i < arbRoute.opportunities.length; i++) {
            // Scale arbitrage profit to the actual trade amount
            uint scaledProfit = (arbRoute.opportunities[i].profit * amountIn) / (amountIn / 10); // Scale from test amount
            arbitrageBonus += scaledProfit / 2; // Conservative estimate
        }

        enhancedOutput = baseOutput + arbitrageBonus;
        return enhancedOutput;
    }

    // Helper functions for advanced algorithms

    function selectBestIntermediateToken(
        address fromToken,
        address toToken,
        address[] memory usedTokens,
        uint usedCount
    ) internal view returns (address bestToken) {
        address[] memory candidates = getAllWhitelistedTokens();
        uint bestScore = 0;

        for (uint i = 0; i < candidates.length; i++) {
            if (candidates[i] == fromToken || candidates[i] == toToken) continue;

            // Check if already used
            bool alreadyUsed = false;
            for (uint j = 0; j < usedCount; j++) {
                if (usedTokens[j] == candidates[i]) {
                    alreadyUsed = true;
                    break;
                }
            }
            if (alreadyUsed) continue;

            // Calculate combined liquidity and actual output score
            uint liquidityScore = 0;
            uint outputScore = 0;
            
            // Test actual swap output through this intermediate
            address[] memory testPath = new address[](3);
            testPath[0] = fromToken;
            testPath[1] = candidates[i];
            testPath[2] = toToken;
            
            for (uint k = 0; k < routers.length; k++) {
                if (routers[k] == address(0)) continue;
                
                try IUniswapV2Router02(routers[k]).getAmountsOut(1000, testPath) returns (uint[] memory amounts) {
                    if (amounts.length > 2 && amounts[amounts.length - 1] > outputScore) {
                        outputScore = amounts[amounts.length - 1];
                    }
                } catch {}
            }
            
            // Calculate liquidity depth
            uint liquidityIn = analyzeLiquidityDepth(fromToken, candidates[i]);
            uint liquidityOut = analyzeLiquidityDepth(candidates[i], toToken);
            liquidityScore = sqrt(liquidityIn * liquidityOut);
            
            // Combined score (70% output, 30% liquidity)
            uint combinedScore = (outputScore * 7 + liquidityScore * 3) / 10;

            if (combinedScore > bestScore) {
                bestScore = combinedScore;
                bestToken = candidates[i];
            }
        }

        return bestToken;
    }

    function calculateRoutePriceImpact(
        uint amountIn,
        TradeRoute memory route
    ) internal view returns (uint totalImpact) {
        uint currentAmount = amountIn;

        for (uint hop = 0; hop < route.hops; hop++) {
            Split[] memory hopSplits = route.splitRoutes[hop];
            uint hopImpact = 0;

            for (uint i = 0; i < hopSplits.length; i++) {
                uint splitAmount = (currentAmount * hopSplits[i].percentage) / 10000;
                uint impact = calculateSplitPriceImpact(splitAmount, hopSplits[i]);
                hopImpact += impact * hopSplits[i].percentage / 10000;
            }

            totalImpact += hopImpact;
            // Update current amount for next hop (simplified)
            currentAmount = currentAmount * 95 / 100; // Assume 5% loss per hop
        }

        return totalImpact;
    }

    function calculateSplitPriceImpact(
        uint amountIn,
        Split memory split
    ) internal view returns (uint impact) {
        if (split.path.length < 2) return 0;

        // Calculate small amount output
        uint smallAmount = amountIn / 10;
        uint largeAmount = amountIn;

        try IUniswapV2Router02(split.router).getAmountsOut(smallAmount, split.path) returns (uint[] memory smallRes) {
            try IUniswapV2Router02(split.router).getAmountsOut(largeAmount, split.path) returns (uint[] memory largeRes) {
                if (smallRes.length > 1 && largeRes.length > 1) {
                    uint expectedLarge = (smallRes[smallRes.length - 1] * largeAmount) / smallAmount;
                    uint actualLarge = largeRes[largeRes.length - 1];

                    if (expectedLarge > actualLarge) {
                        impact = ((expectedLarge - actualLarge) * 10000) / expectedLarge;
                    }
                }
            } catch {}
        } catch {}

        return impact;
    }

    function addIntermediateHop(
        uint amountIn,
        TradeRoute memory route
    ) internal view returns (TradeRoute memory extendedRoute) {
        if (route.hops >= MAX_HOPS) return route;

        extendedRoute.inputToken = route.inputToken;
        extendedRoute.outputToken = route.outputToken;
        extendedRoute.hops = route.hops + 1;
        extendedRoute.splitRoutes = new Split[][](route.hops + 1);

        // Find best position to insert new hop
        uint bestPosition = route.hops / 2;
        address intermediateToken = selectBestIntermediateToken(
            route.inputToken,
            route.outputToken,
            new address[](0),
            0
        );

        if (intermediateToken == address(0)) return route;

        // Copy existing splits and insert new hop
        for (uint i = 0; i <= bestPosition; i++) {
            extendedRoute.splitRoutes[i] = route.splitRoutes[i];
        }

        // Create new intermediate hop
        (uint hopOutput, Split[] memory newSplits) = findBestSplitForHop(
            amountIn / 2, // Simplified amount estimation
            intermediateToken,
            route.outputToken,
            new address[](0)
        );

        if (hopOutput > 0) {
            extendedRoute.splitRoutes[bestPosition + 1] = newSplits;

            for (uint i = bestPosition + 2; i < extendedRoute.hops; i++) {
                extendedRoute.splitRoutes[i] = route.splitRoutes[i - 1];
            }
        } else {
            return route;
        }

        return extendedRoute;
    }

    function optimizeSplitPercentagesAdvanced(
        uint amountIn,
        Split[] memory splits
    ) internal view returns (Split[] memory optimizedSplits) {
        if (splits.length <= 1) return splits;

        // Use iterative optimization to find best percentages
        uint[] memory bestPercentages = new uint[](splits.length);
        uint bestOutput = 0;

        // Try different distribution strategies
        uint[][] memory strategies = generateAdvancedDistributions(splits.length);

        for (uint s = 0; s < strategies.length; s++) {
            uint output = calculateSplitOutputWithPercentages(amountIn, splits, strategies[s]);
            if (output > bestOutput) {
                bestOutput = output;
                bestPercentages = strategies[s];
            }
        }

        // Apply best percentages
        optimizedSplits = new Split[](splits.length);
        for (uint i = 0; i < splits.length; i++) {
            optimizedSplits[i] = splits[i];
            optimizedSplits[i].percentage = bestPercentages[i];
        }

        return optimizedSplits;
    }

    function generateAdvancedDistributions(uint splitCount) internal pure returns (uint[][] memory) {
        uint strategies = 10;
        uint[][] memory distributions = new uint[][](strategies);

        // Strategy 1: Equal distribution
        distributions[0] = new uint[](splitCount);
        uint equalShare = 10000 / splitCount;
        for (uint i = 0; i < splitCount; i++) {
            distributions[0][i] = equalShare;
        }
        if (10000 % splitCount != 0) {
            distributions[0][0] += 10000 % splitCount;
        }

        // Strategy 2-10: Various weighted distributions
        for (uint s = 1; s < strategies; s++) {
            distributions[s] = new uint[](splitCount);
            uint base = 10000 / (splitCount * 2);
            uint multiplier = s;

            uint total = 0;
            for (uint i = 0; i < splitCount - 1; i++) {
                distributions[s][i] = base * (multiplier + i);
                total += distributions[s][i];
            }
            distributions[s][splitCount - 1] = 10000 - total;
        }

        return distributions;
    }

    function calculateSplitOutputWithPercentages(
        uint amountIn,
        Split[] memory splits,
        uint[] memory percentages
    ) internal view returns (uint totalOutput) {
        for (uint i = 0; i < splits.length; i++) {
            uint splitAmount = (amountIn * percentages[i]) / 10000;
            if (splitAmount == 0) continue;

            try IUniswapV2Router02(splits[i].router).getAmountsOut(splitAmount, splits[i].path) returns (uint[] memory amounts) {
                if (amounts.length > 1) {
                    totalOutput += amounts[amounts.length - 1];
                }
            } catch {}
        }

        return totalOutput;
    }

    function simulateRoute(
        uint amountIn,
        TradeRoute memory route
    ) internal view returns (uint finalOutput) {
        uint currentAmount = amountIn;

        for (uint hop = 0; hop < route.hops; hop++) {
            uint hopOutput = 0;
            Split[] memory hopSplits = route.splitRoutes[hop];

            for (uint i = 0; i < hopSplits.length; i++) {
                uint splitAmount = (currentAmount * hopSplits[i].percentage) / 10000;
                if (splitAmount == 0) continue;

                try IUniswapV2Router02(hopSplits[i].router).getAmountsOut(splitAmount, hopSplits[i].path) returns (uint[] memory amounts) {
                    if (amounts.length > 1) {
                        hopOutput += amounts[amounts.length - 1];
                    }
                } catch {}
            }

            currentAmount = hopOutput;
            if (currentAmount == 0) return 0;
        }

        return currentAmount;
    }

    function calculateRouteScore(
        TradeRoute memory route,
        uint amountIn
    ) internal view returns (uint score) {
        if (route.totalExpectedOutput == 0 || amountIn == 0) return 0;

        // Base score: output ratio
        uint outputRatio = (route.totalExpectedOutput * 1000) / amountIn;

        // Penalty for too many hops (gas cost)
        uint hopPenalty = route.hops > 4 ? (route.hops - 4) * 50 : 0;

        // Bonus for using multiple splits (better price)
        uint splitBonus = 0;
        for (uint i = 0; i < route.hops; i++) {
            if (route.splitRoutes[i].length > 1) {
                splitBonus += 10;
            }
        }

        score = outputRatio + splitBonus;
        if (score > hopPenalty) {
            score -= hopPenalty;
        } else {
            score = 0;
        }

        return score;
    }

    // Dynamic whitelist management
    address[] private whitelistedTokenArray;
    
    // Keep existing core functions with modifications for 8-hop support
    function getAllWhitelistedTokens() internal view returns (address[] memory) {
        return whitelistedTokenArray;
    }
    
    function getCommonStablecoins() internal pure returns (address[] memory) {
        address[] memory stablecoins = new address[](2);
        stablecoins[0] = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea;
        stablecoins[1] = 0x88b8E2161DEDC77EF4ab7585569D2415a1C1055D;
        return stablecoins;
    }
    
    function getWhitelistedTokensCount() external view returns (uint) {
        return whitelistedTokenArray.length;
    }
    
    function getWhitelistedTokenAt(uint index) external view returns (address) {
        require(index < whitelistedTokenArray.length, "Index out of bounds");
        return whitelistedTokenArray[index];
    }

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
                            } catch {}

                            try IERC20(tokenB).decimals() returns (uint8 dec) {
                                decimalsB = dec;
                            } catch {}

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

                            if (adjustedReserve0 > 0 && adjustedReserve1 > 0) {
                                uint liquidity = sqrt(adjustedReserve0 * adjustedReserve1);
                                totalLiquidity += liquidity;
                            }
                        } catch {}
                    }
                } catch {}
            } catch {}
        }

        return totalLiquidity;
    }

    function sqrt(uint x) internal pure returns (uint y) {
        if (x == 0) return 0;
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function getBestIntermediateTokens(address tokenIn, address tokenOut, uint maxCount) internal view returns (address[] memory) {
        address[] memory allWhitelisted = getAllWhitelistedTokens();
        if (allWhitelisted.length == 0) return new address[](0);
        
        uint[] memory liquidityScores = new uint[](allWhitelisted.length);
        uint validCount = 0;
        
        // Calculate liquidity scores for each whitelisted token
        for (uint i = 0; i < allWhitelisted.length; i++) {
            if (allWhitelisted[i] == tokenIn || allWhitelisted[i] == tokenOut) continue;
            
            uint liquidityIn = analyzeLiquidityDepth(tokenIn, allWhitelisted[i]);
            uint liquidityOut = analyzeLiquidityDepth(allWhitelisted[i], tokenOut);
            
            if (liquidityIn > 0 && liquidityOut > 0) {
                liquidityScores[i] = sqrt(liquidityIn * liquidityOut);
                validCount++;
            }
        }
        
        if (validCount == 0) return new address[](0);
        
        // Sort by liquidity scores (simple bubble sort for small arrays)
        for (uint i = 0; i < allWhitelisted.length; i++) {
            for (uint j = i + 1; j < allWhitelisted.length; j++) {
                if (liquidityScores[j] > liquidityScores[i]) {
                    uint tempScore = liquidityScores[i];
                    liquidityScores[i] = liquidityScores[j];
                    liquidityScores[j] = tempScore;
                    
                    address tempToken = allWhitelisted[i];
                    allWhitelisted[i] = allWhitelisted[j];
                    allWhitelisted[j] = tempToken;
                }
            }
        }
        
        // Return top tokens up to maxCount
        uint returnCount = validCount > maxCount ? maxCount : validCount;
        address[] memory bestTokens = new address[](returnCount);
        uint added = 0;
        
        for (uint i = 0; i < allWhitelisted.length && added < returnCount; i++) {
            if (liquidityScores[i] > 0) {
                bestTokens[added] = allWhitelisted[i];
                added++;
            }
        }
        
        return bestTokens;
    }

    function getPath(address tokenIn, address tokenOut) internal view returns (address[] memory) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) {
            address[] memory emptyPath = new address[](2);
            emptyPath[0] = tokenIn;
            emptyPath[1] = tokenOut;
            return emptyPath;
        }

        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;

        // Check direct path first
        bool hasDirectLiquidity = false;
        uint bestDirectOutput = 0;
        
        for (uint i = 0; i < routers.length && !hasDirectLiquidity; i++) {
            if (routers[i] == address(0)) continue;

            try IUniswapV2Router02(routers[i]).getAmountsOut(1000, directPath) returns (uint[] memory amounts) {
                if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                    hasDirectLiquidity = true;
                    if (amounts[amounts.length - 1] > bestDirectOutput) {
                        bestDirectOutput = amounts[amounts.length - 1];
                    }
                }
            } catch {}
        }

        // Try paths through whitelisted intermediate tokens
        address[] memory intermediates = getBestIntermediateTokens(tokenIn, tokenOut, 5);
        uint bestIntermediateOutput = 0;
        address[] memory bestIntermediatePath;

        for (uint i = 0; i < intermediates.length; i++) {
            address intermediate = intermediates[i];
            if (intermediate == address(0)) continue;

            address[] memory intermediatePath = new address[](3);
            intermediatePath[0] = tokenIn;
            intermediatePath[1] = intermediate;
            intermediatePath[2] = tokenOut;

            for (uint j = 0; j < routers.length; j++) {
                if (routers[j] == address(0)) continue;

                try IUniswapV2Router02(routers[j]).getAmountsOut(1000, intermediatePath) returns (uint[] memory amounts) {
                    if (amounts.length > 2 && amounts[amounts.length - 1] > bestIntermediateOutput) {
                        bestIntermediateOutput = amounts[amounts.length - 1];
                        bestIntermediatePath = intermediatePath;
                    }
                } catch {}
            }
        }

        // Return the best path found
        if (hasDirectLiquidity && bestDirectOutput >= bestIntermediateOutput) {
            return directPath;
        } else if (bestIntermediateOutput > 0) {
            return bestIntermediatePath;
        }

        // Fallback to direct path
        return directPath;
    }

    // Enhanced findBestSplitForHop for 8-hop support
    function findBestSplitForHop(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory forbiddenTokens
    ) public view returns (uint expectedOut, Split[] memory splits) {
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
            percentage: 10000,
            path: getPath(tokenIn, tokenOut),
            expectedOutput: bestAmountOut,
            priceImpact: calculateSplitPriceImpact(amountIn, bestSplits[0])
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
                            address[] memory splitPath = getPath(tokenIn, tokenOut);
                            bestSplits[splitIndex] = Split({
                                router: topRouters[i],
                                percentage: optimizedPercentages[i],
                                path: splitPath,
                                expectedOutput: (routerOutputs[i] * optimizedPercentages[i]) / 10000,
                                priceImpact: calculateSplitPriceImpact((amountIn * optimizedPercentages[i]) / 10000, bestSplits[splitIndex])
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
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || amountIn == 0) {
            return (address(0), 0);
        }

        bestAmountOut = 0;
        bestRouter = address(0);

        address[] memory directPath = new address[](2);
        directPath[0] = tokenIn;
        directPath[1] = tokenOut;

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
            } catch {}
        }

        if (bestAmountOut > 0) {
            return (bestRouter, bestAmountOut);
        }

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
                } catch {}
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
        require(count <= routers.length, "Count exceeds router count");

        topRouters = new address[](count);
        amountsOut = new uint[](count);

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

        for (uint i = 0; i < validRouterCount; i++) {
            for (uint j = i + 1; j < validRouterCount; j++) {
                if (allAmounts[j] > allAmounts[i]) {
                    uint tempAmount = allAmounts[i];
                    allAmounts[i] = allAmounts[j];
                    allAmounts[j] = tempAmount;

                    address tempRouter = allRouters[i];
                    allRouters[i] = allRouters[j];
                    allRouters[j] = tempRouter;
                }
            }
        }

        for (uint i = 0; i < count && i < validRouterCount; i++) {
            if (allAmounts[i] > 0) {
                topRouters[i] = allRouters[i];
                amountsOut[i] = allAmounts[i];
            }
        }

        return (topRouters, amountsOut);
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
        bestOutput = 0;

        // Use genetic algorithm for split optimization
        uint[][] memory testDistributions = generateTestDistributions(splitRouters);

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

    function calculateSplitOutput(
        uint amountIn,
        address tokenIn,
        address tokenOut,
        address[] memory splitRouters,
        uint[] memory splitPercentages
    ) internal view returns (uint totalOutput) {
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
            } catch {}
        }

        return totalOutput;
    }

    function generateTestDistributions(address[] memory splitRouters) internal pure returns (uint[][] memory) {
        uint routerCount = 0;
        for (uint i = 0; i < splitRouters.length; i++) {
            if (splitRouters[i] != address(0)) {
                routerCount++;
            }
        }

        uint distributionCount = 50; // Increased for better optimization
        uint[][] memory testDistributions = new uint[][](distributionCount);

        for (uint d = 0; d < distributionCount; d++) {
            testDistributions[d] = new uint[](splitRouters.length);

            if (d == 0) {
                // Equal distribution
                uint equalShare = 10000 / routerCount;
                uint assigned = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (splitRouters[i] != address(0)) {
                        testDistributions[d][i] = equalShare;
                        assigned += equalShare;
                    }
                }
                if (assigned < 10000) {
                    for (uint i = 0; i < splitRouters.length; i++) {
                        if (splitRouters[i] != address(0)) {
                            testDistributions[d][i] += (10000 - assigned);
                            break;
                        }
                    }
                }
            } else {
                // Various weighted distributions
                uint remaining = 10000;
                uint validRouters = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (splitRouters[i] != address(0)) {
                        validRouters++;
                    }
                }

                uint routerIndex = 0;
                for (uint i = 0; i < splitRouters.length; i++) {
                    if (splitRouters[i] != address(0)) {
                        if (routerIndex == validRouters - 1) {
                            testDistributions[d][i] = remaining;
                        } else {
                            uint weight = ((d * 137 + routerIndex * 73) % 8000) + 500; // Random weight
                            if (weight > remaining) weight = remaining;
                            testDistributions[d][i] = weight;
                            remaining -= weight;
                        }
                        routerIndex++;
                    }
                }
            }
        }

        return testDistributions;
    }

    function calculateDynamicSlippage(address inputToken, address outputToken, uint expectedOut) internal view returns (uint slippageBps) {
        slippageBps = defaultSlippageBps;

        uint8 decimalsIn = 18;
        uint8 decimalsOut = 18;

        try IERC20(inputToken).decimals() returns (uint8 dec) {
            decimalsIn = dec;
        } catch {}

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

        // Validate intermediate tokens - only whitelisted tokens can be used as intermediates
        // Exception: input/output tokens can be used even if not whitelisted
        for (uint i = 0; i < route.hops; i++) {
            for (uint j = 0; j < route.splitRoutes[i].length; j++) {
                Split memory split = route.splitRoutes[i][j];
                require(split.router != address(0), "Invalid router");
                require(split.path.length >= 2, "Invalid path length");

                for (uint k = 0; k < split.path.length; k++) {
                    address token = split.path[k];
                    require(token != address(0), "Invalid token in path");

                    // Allow input and output tokens even if not whitelisted
                    if (token == route.inputToken || token == route.outputToken) {
                        continue;
                    } else {
                        // All other intermediate tokens must be whitelisted
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
