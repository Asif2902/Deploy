const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MonBridgeDex", function () {
    let MonBridgeDex;
    let monBridgeDex;
    let owner;
    let addr1;
    let addr2;
    let mockWETH;
    let tokenA;
    let tokenB;
    let tokenC;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy MockWETH
        const MockWETHFactory = await ethers.getContractFactory("MockWETH");
        mockWETH = await MockWETHFactory.deploy();
        await mockWETH.waitForDeployment();
        const wethAddress = await mockWETH.getAddress();

        // Deploy MonBridgeDex
        MonBridgeDex = await ethers.getContractFactory("MonBridgeDex");
        monBridgeDex = await MonBridgeDex.deploy(wethAddress);
        await monBridgeDex.waitForDeployment();

        // Deploy MockERC20 tokens for testing
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        tokenA = await MockERC20Factory.deploy("Token A", "TKA", 18, ethers.parseUnits("1000000", 18));
        await tokenA.waitForDeployment();
        tokenB = await MockERC20Factory.deploy("Token B", "TKB", 18, ethers.parseUnits("1000000", 18));
        await tokenB.waitForDeployment();
        tokenC = await MockERC20Factory.deploy("Token C", "TKC", 18, ethers.parseUnits("1000000", 18));
        await tokenC.waitForDeployment();
    });

    describe("Admin Functions for Dynamic Token Lists", function () {
        describe("Common Intermediate Tokens", function () {
            it("Should allow owner to add common intermediate tokens", async function () {
                const tokenAddresses = [await tokenA.getAddress(), await tokenB.getAddress()];
                await expect(monBridgeDex.connect(owner).addCommonIntermediateTokens(tokenAddresses))
                    .to.emit(monBridgeDex, "CommonIntermediateTokenAdded").withArgs(await tokenA.getAddress())
                    .and.to.emit(monBridgeDex, "CommonIntermediateTokenAdded").withArgs(await tokenB.getAddress());

                const intermediates = await monBridgeDex.getCommonIntermediates();
                expect(intermediates).to.deep.equal(tokenAddresses);
            });

            it("Should prevent non-owner from adding common intermediate tokens", async function () {
                const tokenAddresses = [await tokenA.getAddress()];
                await expect(monBridgeDex.connect(addr1).addCommonIntermediateTokens(tokenAddresses))
                    .to.be.revertedWithCustomError(monBridgeDex, "OwnableUnauthorizedAccount")
                    .withArgs(addr1.address);
            });

            it("Should prevent adding duplicate common intermediate tokens", async function () {
                const tokenAddresses = [await tokenA.getAddress(), await tokenA.getAddress()];
                await monBridgeDex.connect(owner).addCommonIntermediateTokens([await tokenA.getAddress()]); // Add once
                
                // Attempt to add again (with duplicates in input)
                await monBridgeDex.connect(owner).addCommonIntermediateTokens(tokenAddresses);

                const intermediates = await monBridgeDex.getCommonIntermediates();
                expect(intermediates).to.deep.equal([await tokenA.getAddress()]); // Should only contain one instance
            });
            
            it("Should prevent adding zero address as common intermediate token", async function () {
                const tokenAddresses = [ethers.ZeroAddress];
                await expect(monBridgeDex.connect(owner).addCommonIntermediateTokens(tokenAddresses))
                    .to.be.revertedWith("Token cannot be zero address");
            });

            it("Should allow owner to remove a common intermediate token", async function () {
                const tokenAAddress = await tokenA.getAddress();
                const tokenBAddress = await tokenB.getAddress();
                await monBridgeDex.connect(owner).addCommonIntermediateTokens([tokenAAddress, tokenBAddress]);

                await expect(monBridgeDex.connect(owner).removeCommonIntermediateToken(tokenAAddress))
                    .to.emit(monBridgeDex, "CommonIntermediateTokenRemoved").withArgs(tokenAAddress);

                const intermediates = await monBridgeDex.getCommonIntermediates();
                expect(intermediates).to.deep.equal([tokenBAddress]); // Token A should be removed
            });

            it("Should handle removing a non-existent common intermediate token gracefully", async function () {
                const tokenAAddress = await tokenA.getAddress();
                // Try to remove a token that hasn't been added
                await expect(monBridgeDex.connect(owner).removeCommonIntermediateToken(tokenAAddress))
                    .to.not.emit(monBridgeDex, "CommonIntermediateTokenRemoved"); // Event should not be emitted
                
                const intermediates = await monBridgeDex.getCommonIntermediates();
                expect(intermediates).to.be.empty;
            });

            it("Should prevent non-owner from removing common intermediate tokens", async function () {
                const tokenAAddress = await tokenA.getAddress();
                await monBridgeDex.connect(owner).addCommonIntermediateTokens([tokenAAddress]);
                await expect(monBridgeDex.connect(addr1).removeCommonIntermediateToken(tokenAAddress))
                    .to.be.revertedWithCustomError(monBridgeDex, "OwnableUnauthorizedAccount")
                    .withArgs(addr1.address);
            });
        });

        describe("Common Stablecoin Tokens", function () {
            it("Should allow owner to add common stablecoin tokens", async function () {
                const tokenAddresses = [await tokenA.getAddress(), await tokenB.getAddress()];
                await expect(monBridgeDex.connect(owner).addCommonStablecoinTokens(tokenAddresses))
                    .to.emit(monBridgeDex, "CommonStablecoinTokenAdded").withArgs(await tokenA.getAddress())
                    .and.to.emit(monBridgeDex, "CommonStablecoinTokenAdded").withArgs(await tokenB.getAddress());

                const stablecoins = await monBridgeDex.getCommonStablecoins();
                expect(stablecoins).to.deep.equal(tokenAddresses);
            });

            it("Should prevent non-owner from adding common stablecoin tokens", async function () {
                const tokenAddresses = [await tokenA.getAddress()];
                await expect(monBridgeDex.connect(addr1).addCommonStablecoinTokens(tokenAddresses))
                    .to.be.revertedWithCustomError(monBridgeDex, "OwnableUnauthorizedAccount")
                    .withArgs(addr1.address);
            });
            
            it("Should prevent adding duplicate common stablecoin tokens", async function () {
                const tokenAddresses = [await tokenA.getAddress(), await tokenA.getAddress()];
                await monBridgeDex.connect(owner).addCommonStablecoinTokens([await tokenA.getAddress()]); // Add once
                
                await monBridgeDex.connect(owner).addCommonStablecoinTokens(tokenAddresses);

                const stablecoins = await monBridgeDex.getCommonStablecoins();
                expect(stablecoins).to.deep.equal([await tokenA.getAddress()]);
            });

            it("Should prevent adding zero address as common stablecoin token", async function () {
                const tokenAddresses = [ethers.ZeroAddress];
                await expect(monBridgeDex.connect(owner).addCommonStablecoinTokens(tokenAddresses))
                    .to.be.revertedWith("Token cannot be zero address");
            });

            it("Should allow owner to remove a common stablecoin token", async function () {
                const tokenAAddress = await tokenA.getAddress();
                const tokenBAddress = await tokenB.getAddress();
                await monBridgeDex.connect(owner).addCommonStablecoinTokens([tokenAAddress, tokenBAddress]);

                await expect(monBridgeDex.connect(owner).removeCommonStablecoinToken(tokenAAddress))
                    .to.emit(monBridgeDex, "CommonStablecoinTokenRemoved").withArgs(tokenAAddress);

                const stablecoins = await monBridgeDex.getCommonStablecoins();
                expect(stablecoins).to.deep.equal([tokenBAddress]);
            });

            it("Should handle removing a non-existent common stablecoin token gracefully", async function () {
                const tokenAAddress = await tokenA.getAddress();
                await expect(monBridgeDex.connect(owner).removeCommonStablecoinToken(tokenAAddress))
                    .to.not.emit(monBridgeDex, "CommonStablecoinTokenRemoved");
                const stablecoins = await monBridgeDex.getCommonStablecoins();
                expect(stablecoins).to.be.empty;
            });

            it("Should prevent non-owner from removing common stablecoin tokens", async function () {
                 const tokenAAddress = await tokenA.getAddress();
                await monBridgeDex.connect(owner).addCommonStablecoinTokens([tokenAAddress]);
                await expect(monBridgeDex.connect(addr1).removeCommonStablecoinToken(tokenAAddress))
                    .to.be.revertedWithCustomError(monBridgeDex, "OwnableUnauthorizedAccount")
                    .withArgs(addr1.address);
            });
        });

        describe("getAllWhitelistedTokens()", function () {
            const wethAddressPromise = monBridgeDex ? monBridgeDex.WETH() : Promise.resolve(ethers.ZeroAddress); // Handle case where monBridgeDex might not be initialized for a dry run
            
            it("Should return only WETH if no other tokens are whitelisted or added to common lists", async function () {
                const wethAddr = await wethAddressPromise;
                // By default, WETH is whitelisted in the constructor.
                // We need to remove it from whitelistedTokens for this specific test, then add it back for others.
                // However, the current `whitelistedTokens` is a mapping, items can't be "removed" to empty, only set to false.
                // The function `getAllWhitelistedTokens` *always* includes WETH if WETH is not address(0).
                // So, this test will always include WETH.

                const allTokens = await monBridgeDex.getAllWhitelistedTokens();
                expect(allTokens).to.have.members([wethAddr]);
                expect(allTokens.length).to.equal(1); // Only WETH
            });

            it("Should include WETH, common intermediates, and common stablecoins without duplicates", async function () {
                const wethAddr = await wethAddressPromise;
                const tokenAAddress = await tokenA.getAddress();
                const tokenBAddress = await tokenB.getAddress();
                const tokenCAddress = await tokenC.getAddress();

                // tokenA is common intermediate, tokenB is common stablecoin, tokenC is also intermediate
                // WETH is whitelisted by default. tokenA is also WETH for one test case.
                
                await monBridgeDex.connect(owner).addCommonIntermediateTokens([tokenAAddress, tokenCAddress]);
                await monBridgeDex.connect(owner).addCommonStablecoinTokens([tokenBAddress, tokenAAddress]); // tokenA is duplicated here

                const allTokens = await monBridgeDex.getAllWhitelistedTokens();
                
                // Expected: WETH, tokenA, tokenB, tokenC
                // (tokenA is common intermediate and common stable, but should appear once)
                // (WETH is whitelisted by default)
                const expectedMembers = [wethAddr, tokenAAddress, tokenBAddress, tokenCAddress];
                expect(allTokens).to.have.members(expectedMembers);
                // Ensure no duplicates in the final list returned by the contract
                const uniqueMembersInResult = new Set(allTokens.map(addr => addr.toLowerCase()));
                expect(uniqueMembersInResult.size).to.equal(expectedMembers.length);
            });

            it("Should correctly handle WETH being part of common lists", async function () {
                const wethAddr = await wethAddressPromise;
                const tokenBAddress = await tokenB.getAddress();

                await monBridgeDex.connect(owner).addCommonIntermediateTokens([wethAddr]);
                await monBridgeDex.connect(owner).addCommonStablecoinTokens([tokenBAddress]);

                const allTokens = await monBridgeDex.getAllWhitelistedTokens();
                const expectedMembers = [wethAddr, tokenBAddress];
                
                expect(allTokens).to.have.members(expectedMembers);
                const uniqueMembersInResult = new Set(allTokens.map(addr => addr.toLowerCase()));
                expect(uniqueMembersInResult.size).to.equal(expectedMembers.length);
            });
             it("Should return all unique tokens when WETH is also a common intermediate and stablecoin", async function () {
                const wethAddr = await wethAddressPromise;
                await monBridgeDex.connect(owner).addCommonIntermediateTokens([wethAddr]);
                await monBridgeDex.connect(owner).addCommonStablecoinTokens([wethAddr]);
                
                const allTokens = await monBridgeDex.getAllWhitelistedTokens();
                expect(allTokens).to.have.members([wethAddr]); // WETH is always included
                expect(allTokens.length).to.equal(1); // Only WETH, no duplicates
            });

            it("Should return an empty array (plus WETH) if all lists are empty and WETH is the only whitelisted", async function () {
                const wethAddr = await wethAddressPromise;
                // Note: WETH is whitelisted by default in constructor.
                // To test a truly empty scenario without WETH, WETH itself would need to be non-address(0) but not whitelisted.
                // However, getAllWhitelistedTokens logic *always* adds WETH if WETH != address(0).
                const commonIntermediates = await monBridgeDex.getCommonIntermediates();
                const commonStablecoins = await monBridgeDex.getCommonStablecoins();
                expect(commonIntermediates.length).to.equal(0);
                expect(commonStablecoins.length).to.equal(0);

                const allTokens = await monBridgeDex.getAllWhitelistedTokens();
                expect(allTokens).to.deep.equal([wethAddr]);
            });
        });

        describe("Router Max Hops", function() {
            let router1Address;

            beforeEach(async function() {
                // Add a router for these tests
                const MockRouterFactory = await ethers.getContractFactory("MockUniswapV2Router02");
                const mockRouter1 = await MockRouterFactory.deploy(await mockWETH.getAddress());
                await mockRouter1.waitForDeployment();
                router1Address = await mockRouter1.getAddress();
                await monBridgeDex.connect(owner).addRouters([router1Address]);
            });

            it("Should allow owner to set routerMaxHops for a registered router", async function() {
                await expect(monBridgeDex.connect(owner).setRouterMaxHops(router1Address, 4))
                    .to.emit(monBridgeDex, "RouterMaxHopsUpdated")
                    .withArgs(router1Address, 4);
                expect(await monBridgeDex.routerMaxHops(router1Address)).to.equal(4);
            });

            it("Should prevent non-owner from setting routerMaxHops", async function() {
                await expect(monBridgeDex.connect(addr1).setRouterMaxHops(router1Address, 4))
                    .to.be.revertedWithCustomError(monBridgeDex, "OwnableUnauthorizedAccount")
                    .withArgs(addr1.address);
            });

            it("Should revert if setting routerMaxHops for a non-existent router", async function() {
                const nonExistentRouterAddress = addr2.address; // An address not added as a router
                await expect(monBridgeDex.connect(owner).setRouterMaxHops(nonExistentRouterAddress, 3))
                    .to.be.revertedWith("Router: not found");
            });

            it("Should revert if routerMaxHops value is out of range (less than 2)", async function() {
                await expect(monBridgeDex.connect(owner).setRouterMaxHops(router1Address, 1))
                    .to.be.revertedWith("RouterMaxHops: invalid (2-5)");
            });

            it("Should revert if routerMaxHops value is out of range (greater than 5)", async function() {
                await expect(monBridgeDex.connect(owner).setRouterMaxHops(router1Address, 6))
                    .to.be.revertedWith("RouterMaxHops: invalid (2-5)");
            });

            it("Should set default routerMaxHops when a new router is added", async function() {
                const MockRouterFactory2 = await ethers.getContractFactory("MockUniswapV2Router02");
                const mockRouter2 = await MockRouterFactory2.deploy(await mockWETH.getAddress());
                await mockRouter2.waitForDeployment();
                const router2Address = await mockRouter2.getAddress();
                
                await monBridgeDex.connect(owner).addRouters([router2Address]);
                expect(await monBridgeDex.routerMaxHops(router2Address)).to.equal(await monBridgeDex.DEFAULT_ROUTER_PATH_LIMIT());
            });

            it("Should not overwrite existing routerMaxHops when re-adding a router", async function() {
                await monBridgeDex.connect(owner).setRouterMaxHops(router1Address, 4);
                expect(await monBridgeDex.routerMaxHops(router1Address)).to.equal(4);

                // Re-adding the same router
                await monBridgeDex.connect(owner).addRouters([router1Address]);
                expect(await monBridgeDex.routerMaxHops(router1Address)).to.equal(4); // Should remain 4, not reset to default
            });
        });
    });
});
