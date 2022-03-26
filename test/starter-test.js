const hre = require('hardhat');
const chai = require('chai');
const {solidity} = require('ethereum-waffle');
chai.use(solidity);
const {expect} = chai;

const moveTimeForward = async (seconds) => {
  await network.provider.send('evm_increaseTime', [seconds]);
  await network.provider.send('evm_mine');
};

// use with small values in case harvest is block-dependent instead of time-dependent
const moveBlocksForward = async (blocks) => {
  for (let i = 0; i < blocks; i++) {
    await network.provider.send('evm_increaseTime', [1]);
    await network.provider.send('evm_mine');
  }
};

const toWantUnit = (num, isUSDC = false) => {
  if (isUSDC) {
    return ethers.BigNumber.from(num * 10 ** 6);
  }
  return ethers.utils.parseEther(num);
};

describe('Vaults', function () {
  let Vault;
  let vault;

  let Strategy;
  let strategy;

  let Want;
  let want;

  const treasuryAddr = '0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b';
  const paymentSplitterAddress = '0x63cbd4134c2253041F370472c130e92daE4Ff174';
  const wantAddress = '0x04068da6c83afcfa0e13ba15a6696662335d5b75';

  const wantHolderAddr = '0xc5ed2333f8a2c351fca35e5ebadb2a82f5d254c3';
  const strategistAddr = '0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4';

  let owner;
  let wantHolder;
  let strategist;

  beforeEach(async function () {
    //reset network
    await network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl: 'https://rpc.ftm.tools/',
            blockNumber: 34382026,
          },
        },
      ],
    });

    //get signers
    [owner] = await ethers.getSigners();
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [wantHolderAddr],
    });
    wantHolder = await ethers.provider.getSigner(wantHolderAddr);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [strategistAddr],
    });
    strategist = await ethers.provider.getSigner(strategistAddr);

    //get artifacts
    Vault = await ethers.getContractFactory('ReaperVaultv1_4');
    Strategy = await ethers.getContractFactory('ReaperStrategyStargate');
    Want = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');

    //deploy contracts
    vault = await Vault.deploy(wantAddress, 'Stargate USDC Crypt', 'rf-S*USDC', 0, ethers.constants.MaxUint256);
    strategy = await hre.upgrades.deployProxy(
      Strategy,
      [vault.address, [treasuryAddr, paymentSplitterAddress], [strategistAddr]],
      {kind: 'uups'},
    );
    await strategy.deployed();
    await vault.initialize(strategy.address);
    want = await Want.attach(wantAddress);

    //approving LP token and vault share spend
    await want.connect(wantHolder).approve(vault.address, ethers.constants.MaxUint256);
  });

  describe('Deploying the vault and strategy', function () {
    xit('should initiate vault with a 0 balance', async function () {
      const totalBalance = await vault.balance();
      const availableBalance = await vault.available();
      const pricePerFullShare = await vault.getPricePerFullShare();
      expect(totalBalance).to.equal(0);
      expect(availableBalance).to.equal(0);
      expect(pricePerFullShare).to.equal(ethers.utils.parseEther('1'));
    });
  });

  describe('Vault Tests', function () {
    xit('should allow deposits and account for them correctly', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const vaultBalance = await vault.balance();
      const depositAmount = toWantUnit('10', true);
      await vault.connect(wantHolder).deposit(depositAmount);
      const newVaultBalance = await vault.balance();
      const newUserBalance = await want.balanceOf(wantHolderAddr);
      const allowedInaccuracy = depositAmount.div(200);
      expect(depositAmount).to.be.closeTo(newVaultBalance, allowedInaccuracy);
    });
    xit('should mint user their pool share', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('10', true);
      await vault.connect(wantHolder).deposit(depositAmount);
      const ownerDepositAmount = toWantUnit('0.1', true);
      await want.connect(wantHolder).transfer(owner.address, ownerDepositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      await vault.connect(owner).deposit(ownerDepositAmount);
      const allowedImprecision = toWantUnit('0.0001', true);
      const userVaultBalance = await vault.balanceOf(wantHolderAddr);
      expect(userVaultBalance).to.be.closeTo(depositAmount, allowedImprecision);
      const ownerVaultBalance = await vault.balanceOf(owner.address);
      expect(ownerVaultBalance).to.be.closeTo(ownerDepositAmount, allowedImprecision);
      await vault.connect(owner).withdrawAll();
      const ownerWantBalance = await want.balanceOf(owner.address);
      expect(ownerWantBalance).to.be.closeTo(ownerDepositAmount, allowedImprecision);
      const afterOwnerVaultBalance = await vault.balanceOf(owner.address);
      expect(afterOwnerVaultBalance).to.equal(0);
    });
    it('should allow withdrawals', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('100', true);
      await vault.connect(wantHolder).deposit(depositAmount);
      await vault.connect(wantHolder).withdrawAll();
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);
      const securityFee = 10;
      const percentDivisor = 10000;
      const withdrawFee = depositAmount.mul(securityFee).div(percentDivisor);
      const expectedBalance = userBalance.sub(withdrawFee);
      const smallDifference = expectedBalance.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw) < smallDifference;
      expect(isSmallBalanceDifference).to.equal(true);
    });
    xit('should allow small withdrawal', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('0.0001', true);
      await vault.connect(wantHolder).deposit(depositAmount);
      const ownerDepositAmount = toWantUnit('0.1', true);
      await want.connect(wantHolder).transfer(owner.address, ownerDepositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      await vault.connect(owner).deposit(ownerDepositAmount);
      await vault.connect(wantHolder).withdrawAll();
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);
      const securityFee = 10;
      const percentDivisor = 10000;
      const withdrawFee = depositAmount.mul(securityFee).div(percentDivisor);
      const expectedBalance = userBalance.sub(withdrawFee);
      const smallDifference = expectedBalance.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw) < smallDifference;
      expect(isSmallBalanceDifference).to.equal(true);
    });
    xit('should handle small deposit + withdraw', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('0.001');
      await vault.connect(wantHolder).deposit(depositAmount);
      await vault.connect(wantHolder).withdraw(depositAmount);
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);
      const securityFee = 10;
      const percentDivisor = 10000;
      const withdrawFee = (depositAmount * securityFee) / percentDivisor;
      const expectedBalance = userBalance.sub(withdrawFee);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw) < 200;
      expect(isSmallBalanceDifference).to.equal(true);
    });
    // it('should be able to harvest', async function () {
    //   await vault.connect(wantHolder).deposit(toWantUnit('100000'));
    //   await strategy.harvest();
    // });
    xit('should provide yield', async function () {
      const blocksToSkip = 100;
      const depositAmount = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount);
      const initialVaultBalance = await vault.balance();
      await strategy.updateHarvestLogCadence(1);
      const numHarvests = 5;
      for (let i = 0; i < numHarvests; i++) {
        await moveBlocksForward(blocksToSkip);
        await strategy.harvest();
      }
      const finalVaultBalance = await vault.balance();
      expect(finalVaultBalance).to.be.gt(initialVaultBalance);
      const averageAPR = await strategy.averageAPRAcrossLastNHarvests(numHarvests);
      console.log(`Average APR across ${numHarvests} harvests is ${averageAPR} basis points.`);
    });
  });
  describe('Strategy', function () {
    // it('should be able to pause and unpause', async function () {
    //   await strategy.pause();
    //   const depositAmount = toWantUnit('1');
    //   await expect(vault.connect(wantHolder).deposit(depositAmount)).to.be.reverted;
    //   await strategy.unpause();
    //   await expect(vault.connect(wantHolder).deposit(depositAmount)).to.not.be.reverted;
    // });
    // it('should be able to panic', async function () {
    //   const depositAmount = toWantUnit('0.0007');
    //   await vault.connect(wantHolder).deposit(depositAmount);
    //   const vaultBalance = await vault.balance();
    //   const strategyBalance = await strategy.balanceOf();
    //   await strategy.panic();
    //   const wantStratBalance = await want.balanceOf(strategy.address);
    //   const allowedImprecision = toWantUnit('0.000000001');
    //   expect(strategyBalance).to.be.closeTo(wantStratBalance, allowedImprecision);
    // });
    // it('should be able to retire strategy', async function () {
    //   const depositAmount = toWantUnit('100');
    //   await vault.connect(wantHolder).deposit(depositAmount);
    //   const vaultBalance = await vault.balance();
    //   const strategyBalance = await strategy.balanceOf();
    //   expect(vaultBalance).to.equal(strategyBalance);
    //   await expect(strategy.retireStrat()).to.not.be.reverted;
    //   const newVaultBalance = await vault.balance();
    //   const newStrategyBalance = await strategy.balanceOf();
    //   const allowedImprecision = toWantUnit('0.001');
    //   expect(newVaultBalance).to.be.closeTo(vaultBalance, allowedImprecision);
    //   expect(newStrategyBalance).to.be.lt(allowedImprecision);
    // });
    // it('should be able to retire strategy with no balance', async function () {
    //   await expect(strategy.retireStrat()).to.not.be.reverted;
    // });
    // it('should be able to estimate harvest', async function () {
    //   const whaleDepositAmount = toWantUnit('1000');
    //   await vault.connect(wantHolder).deposit(whaleDepositAmount);
    //   await moveBlocksForward(100);
    //   await strategy.harvest();
    //   await moveBlocksForward(100);
    //   const [profit, callFeeToUser] = await strategy.estimateHarvest();
    //   console.log(`profit: ${profit}`);
    //   const hasProfit = profit.gt(0);
    //   const hasCallFee = callFeeToUser.gt(0);
    //   expect(hasProfit).to.equal(true);
    //   expect(hasCallFee).to.equal(true);
    // });
  });
});
