async function main() {
  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');

  const wantAddress = '0x12edeA9cd262006cC3C4E77c90d2CD2DD4b1eb97';
  const tokenName = 'USDC Stargate Crypt';
  const tokenSymbol = 'rf-S*USDC';
  const depositFee = 0;
  const tvlCap = ethers.utils.parseEther('10000');

  const vault = await Vault.deploy(wantAddress, tokenName, tokenSymbol, depositFee, tvlCap);

  await vault.deployed();
  console.log('Vault deployed to:', vault.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
