async function main() {
  const vaultAddress = '0x31d2042842A20de01e78c69a31DA8fBF22D5f208';
  const strategyAddress = '0x5fbbC9C8EC6852A6d52b087f41833f6127674E6B';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);

  await vault.initialize(strategyAddress);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
