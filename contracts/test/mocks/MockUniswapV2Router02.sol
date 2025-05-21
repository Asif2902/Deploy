// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUniswapV2Router02 {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function factory() external pure returns (address); // Mock factory address
}

contract MockUniswapV2Router02 is IUniswapV2Router02 {
    address public constant mockFactory = address(0xCAFECAFECAFECAFECAFECAFECAFECAFECAFECAFE); // Example factory address

    // Mapping to store expected output amounts for specific paths
    // pathHash => expectedAmounts array
    mapping(bytes32 => uint[]) public expectedOutputs;

    // Mapping to store expected input amounts for specific output amounts (for getAmountsIn - not implemented yet)
    // pathHash => expectedAmountsIn array
    // mapping(bytes32 => uint[]) public expectedInputs;

    address public WETH; // WETH address for this mock router

    constructor(address _weth) {
        WETH = _weth;
    }

    function factory() external pure override returns (address) {
        return mockFactory;
    }

    function getPathHash(address[] calldata path) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(path));
    }

    // Admin function to set expected output for a path
    function setExpectedAmountsOut(uint amountIn, address[] calldata path, uint[] calldata amounts) external {
        require(path.length > 0, "Path cannot be empty");
        require(amounts.length == path.length, "Path and amounts length mismatch");
        require(amounts[0] == amountIn, "Amounts[0] must be amountIn");
        bytes32 pathHash = getPathHash(path);
        expectedOutputs[pathHash] = amounts;
    }
    
    // Simplified version for testing: directly set the final output amount for a path, given an input amount
    // This is easier to manage for tests than setting the full amounts array.
    function setExpectedOutput(address tokenIn, address tokenOut, uint amountIn, uint amountOut) external {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint[] memory amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
        setExpectedAmountsOut(amountIn, path, amounts);
    }

    function setExpectedPathOutput(address[] calldata path, uint amountIn, uint finalAmountOut) external {
        require(path.length >= 2, "Path too short");
        uint[] memory amounts = new uint[](path.length);
        amounts[0] = amountIn;
        // For simplicity, we'll just set the last element. Intermediate values won't be accurate
        // unless specifically set by setExpectedAmountsOut.
        for(uint i = 1; i < path.length -1; i++){
            amounts[i] = amountIn; // Dummy intermediate amount
        }
        amounts[path.length - 1] = finalAmountOut;
        setExpectedAmountsOut(amountIn, path, amounts);
    }


    function getAmountsOut(uint amountIn, address[] calldata path) external view override returns (uint[] memory amounts) {
        require(path.length >= 2, "UniswapV2Library: INVALID_PATH");
        bytes32 pathHash = getPathHash(path);
        uint[] memory expected = expectedOutputs[pathHash];

        // Check if the first element of the stored 'expected' amounts (which is an amountIn)
        // matches the provided amountIn. This makes the mock a bit more realistic.
        if (expected.length > 0 && expected[0] == amountIn) {
            return expected;
        }
        
        // Fallback: if no specific mock or amountIn doesn't match, return a simple 1:1 or revert
        // For robust testing, specific paths should be mocked via setExpectedAmountsOut.
        // This fallback simulates a 10% fee if not mocked.
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i = 1; i < path.length; i++) {
            amounts[i] = (amounts[i-1] * 9) / 10; // Simulate 10% drop per hop
        }
        return amounts;
        // Alternatively, revert("MockUniswapV2Router: Path not mocked or amountIn mismatch");
    }

    // --- Swap Functions (Simplified for testing MonBridgeDex execution) ---
    // These will mainly just return the mocked amounts if the path is known
    // and assume the 'to' address receives the tokens.
    // For MonBridgeDex tests, the actual token transfers are handled by MonBridgeDex
    // after it gets the expected output from getAmountsOut.

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "MockRouter: EXPIRED");
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        // In a real router, tokens would be transferred. Here, we just return amounts.
        // The 'to' address is MonBridgeDex itself in the actual flow.
        return amounts;
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable override returns (uint[] memory amounts) {
        require(path[0] == WETH, "MockRouter: INVALID_PATH_ETH");
        require(deadline >= block.timestamp, "MockRouter: EXPIRED");
        amounts = getAmountsOut(msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        return amounts;
    }

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external override returns (uint[] memory amounts) {
        require(path[path.length - 1] == WETH, "MockRouter: INVALID_PATH_ETH");
        require(deadline >= block.timestamp, "MockRouter: EXPIRED");
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        return amounts;
    }
}
