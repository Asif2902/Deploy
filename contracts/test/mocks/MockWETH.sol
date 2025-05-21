// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MockERC20.sol";

contract MockWETH is MockERC20 {
    event Deposit(address indexed dst, uint wad);
    event Withdrawal(address indexed src, uint wad);

    constructor() MockERC20("Wrapped Ether", "WETH", 18, 0) {} // No initial supply from constructor

    function deposit() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint wad) external {
        require(balanceOf[msg.sender] >= wad, "MockWETH: burn amount exceeds balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad; // WETH is burned on withdrawal
        emit Transfer(msg.sender, address(0), wad); // Emit transfer to zero address for burn
        emit Withdrawal(msg.sender, wad);
        payable(msg.sender).transfer(wad);
    }
}
