# Across Mainnet Deployment Addresses

All of the SpokePool addresses listed here are [upgradeable proxy](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/2d081f24cac1a867f6f73d512f2022e1fa987854/contracts/proxy/utils/UUPSUpgradeable.sol) contract addresses. If you want to get implementation contract information (ABI, bytecode, addresses) then go to the relevant folder in this directory for the contract and chain you are looking for. You can read more about the proxy upgradeability pattern we use [here](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/2d081f24cac1a867f6f73d512f2022e1fa987854/contracts/proxy/README.adoc)

The [`deployments.json`](./deployments.json) file also maintains the most up to date **proxy (i.e.not implementation)** addresses and you should view it as the source of truth in case it differs from this `README`.
This is because this `deployments.json` file is used by bots in [`@across-protocol/relayer`](https://github.com/across-protocol/relayer) and [`@across-protocol/sdk`](https://github.com/across-protocol/sdk) to programmatically load the latest contract addresses. This `README` is not a dependency in those repositories so it is more likely to be out of sync with the latest addresses.

## Mainnet (1)

| Contract Name       | Address                                                                                                               |
| ------------------- | --------------------------------------------------------------------------------------------------------------------- |
| LPTokenFactory      | [0x7dB69eb9F52eD773E9b03f5068A1ea0275b2fD9d](https://etherscan.io/address/0x7dB69eb9F52eD773E9b03f5068A1ea0275b2fD9d) |
| HubPool             | [0xc186fA914353c44b2E33eBE05f21846F1048bEda](https://etherscan.io/address/0xc186fA914353c44b2E33eBE05f21846F1048bEda) |
| Optimism_Adapter    | [0xAd1b0a86c98703fd5F4E56fff04F6b2D9b9f246F](https://etherscan.io/address/0xAd1b0a86c98703fd5F4E56fff04F6b2D9b9f246F) |
| Boba_Adapter        | [0x33B0Ec794c15D6Cc705818E70d4CaCe7bCfB5Af3](https://etherscan.io/address/0x33B0Ec794c15D6Cc705818E70d4CaCe7bCfB5Af3) |
| Arbitrum_Adapter    | [0x100EDfCf3af2B4625Fca4EaF6C533703e71F7210](https://etherscan.io/address/0x100EDfCf3af2B4625Fca4EaF6C533703e71F7210) |
| Ethereum_Adapter    | [0x527E872a5c3f0C7c24Fe33F2593cFB890a285084](https://etherscan.io/address/0x527E872a5c3f0C7c24Fe33F2593cFB890a285084) |
| Ethereum_SpokePool  | [0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5](https://etherscan.io/address/0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5) |
| PolygonTokenBridger | [0x48d990AbDA20afa1fD1da713AbC041B60a922c65](https://etherscan.io/address/0x48d990AbDA20afa1fD1da713AbC041B60a922c65) |
| Polygon_Adapter     | [0x3E94e8d4316a1eBfb2245E45E6F0B8724094CE1A](https://etherscan.io/address/0x3E94e8d4316a1eBfb2245E45E6F0B8724094CE1A) |
| ZkSync_Adapter      | [0xE233009838CB898b50e0012a6E783FC9FeE447FB](https://etherscan.io/address/0xE233009838CB898b50e0012a6E783FC9FeE447FB) |
| Base_Adapter        | [0x2d8B1e2B0Dff62DF132d23BEa68a6D2c4D20046E](https://etherscan.io/address/0x2d8B1e2B0Dff62DF132d23BEa68a6D2c4D20046E) |
| Linea Adapter       | [0x7Ea0D1882D610095A45E512B0113f79cA98a8EfE](https://etherscan.io/address/0x7Ea0D1882D610095A45E512B0113f79cA98a8EfE) |
| Mode Adapter        | [0xf1B59868697f3925b72889ede818B9E7ba0316d0](https://etherscan.io/address/0xf1B59868697f3925b72889ede818B9E7ba0316d0) |
| Lisk Adapter        | [0x8229E812f20537caA1e8Fb41749b4887B8a75C3B](https://etherscan.io/address/0x8229E812f20537caA1e8Fb41749b4887B8a75C3B) |
| Blast Adapter       | [0xF2bEf5E905AAE0295003ab14872F811E914EdD81](https://etherscan.io/address/0xF2bEf5E905AAE0295003ab14872F811E914EdD81) |
| Scroll Adapter      | [0xb6129Ab69aEA75e6884c2D6ecf25293C343C519F](https://etherscan.io/address/0xb6129Ab69aEA75e6884c2D6ecf25293C343C519F) |
| Redstone Adapter    | [0x188F8C95B7cfB7993B53a4F643efa687916f73fA](https://etherscan.io/address/0x188F8C95B7cfB7993B53a4F643efa687916f73fA) |
| Zora Adapter        | [0x024F2fC31CBDD8de17194b1892c834f98Ef5169b](https://etherscan.io/address/0x024F2fC31CBDD8de17194b1892c834f98Ef5169b) |
| WorldChain Adapter  | [0x8eBebfc894047bEE213A561b8792fCa71241731f](https://etherscan.io/address/0x8eBebfc894047bEE213A561b8792fCa71241731f) |
| AcrossConfigStore   | [0x3B03509645713718B78951126E0A6de6f10043f5](https://etherscan.io/address/0x3B03509645713718B78951126E0A6de6f10043f5) |
| Across Bond Token   | [0xee1dc6bcf1ee967a350e9ac6caaaa236109002ea](https://etherscan.io/address/0xee1dc6bcf1ee967a350e9ac6caaaa236109002ea) |
| MulticallHandler    | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://etherscan.io/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |
| Cher Adapter        | [0x0c9d064523177dBB55CFE52b9D0c485FBFc35FD2](https://etherscan.io/address/0x0c9d064523177dBB55CFE52b9D0c485FBFc35FD2) |

## Optimism mainnet (10)

| Contract Name      | Address                                                                                                                          |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Optimism_SpokePool | [0x6f26Bf09B1C792e3228e5467807a900A503c0281](https://optimistic.etherscan.io/address/0x6f26Bf09B1C792e3228e5467807a900A503c0281) |
| MulticallHandler   | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://optimistic.etherscan.io/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Polygon mainnet(137)

| Contract Name       | Address                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| PolygonTokenBridger | [0x48d990AbDA20afa1fD1da713AbC041B60a922c65](https://polygonscan.com/address/0x48d990AbDA20afa1fD1da713AbC041B60a922c65) |
| Polygon_SpokePool   | [0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096](https://polygonscan.com/address/0x9295ee1d8C5b022Be115A2AD3c30C72E34e7F096) |
| MulticallHandler    | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://polygonscan.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## zkSync mainnet (324)

| Contract Name    | Address                                                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| zkSync_SpokePool | [0xE0B015E54d54fc84a6cB9B666099c46adE9335FF](https://explorer.zksync.io/address/0xE0B015E54d54fc84a6cB9B666099c46adE9335FF) |
| MulticallHandler | [0x863859ef502F0Ee9676626ED5B418037252eFeb2](https://explorer.zksync.io/address/0x863859ef502F0Ee9676626ED5B418037252eFeb2) |

## Arbitrum mainnet (42161)

| Contract Name      | Address                                                                                                              |
| ------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Arbitrum_SpokePool | [0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A](https://arbiscan.io/address/0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A) |
| MulticallHandler   | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://arbiscan.io/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Base mainnet (8453)

| Contract Name    | Address                                                                                                               |
| ---------------- | --------------------------------------------------------------------------------------------------------------------- |
| Base_SpokePool   | [0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64](https://basescan.org/address/0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64) |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://basescan.org/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Linea mainnet (59144)

| Contract Name    | Address                                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Linea_SpokePool  | [0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75](https://lineascan.build/address/0x7e63a5f1a8f0b4d0934b2f2327daed3f6bb2ee75) |
| MulticallHandler | [0x1015c58894961F4F7Dd7D68ba033e28Ed3ee1cDB](https://lineascan.build/address/0x1015c58894961F4F7Dd7D68ba033e28Ed3ee1cDB) |

## Mode mainnet (34443)

| Contract Name    | Address                                                                                                              |
| ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| Mode_SpokePool   | [0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96](https://modescan.io/address/0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96) |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://modescan.io/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Lisk mainnet (1135)

| Contract Name    | Address                                                                                                                      |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Lisk_SpokePool   | [0x9552a0a6624A23B848060AE5901659CDDa1f83f8](https://blockscout.lisk.com/address/0x9552a0a6624A23B848060AE5901659CDDa1f83f8) |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://blockscout.lisk.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Blast mainnet (81457)

| Contract Name    | Address                                                                                                               |
| ---------------- | --------------------------------------------------------------------------------------------------------------------- |
| Blast_SpokePool  | [0x2D509190Ed0172ba588407D4c2df918F955Cc6E1](https://blastscan.io/address/0x2D509190Ed0172ba588407D4c2df918F955Cc6E1) |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://blastscan.io/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Redstone mainnet (690)

| Contract Name      | Address                                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Redstone_SpokePool | [0x13fDac9F9b4777705db45291bbFF3c972c6d1d97](https://explorer.redstone.xyz/address/0x13fDac9F9b4777705db45291bbFF3c972c6d1d97) |
| MulticallHandler   | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://explorer.redstone.xyz/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Scroll mainnet (534352)

| Contract Name    | Address                                                                                                                 |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Scroll_SpokePool | [0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96](https://scrollscan.com/address/0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96) |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://scrollscan.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Zora mainnet (7777777)

| Contract Name    | Address                                                                                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Zora_SpokePool   | [0x13fDac9F9b4777705db45291bbFF3c972c6d1d97](https://zorascan.xyz/address/0x13fDac9F9b4777705db45291bbFF3c972c6d1d97)         |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://zorascan.xyz/address/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## World Chain mainnet (480)

| Contract Name        | Address                                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| WorldChain_SpokePool | [0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64](https://worldchain-mainnet.explorer.alchemy.com/address/0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64) |
| MulticallHandler     | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://worldchain-mainnet.explorer.alchemy.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## AlephZero mainnet (41455)

| Contract Name       | Address                                                                                                                             |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| AlephZero_SpokePool | [0x13fDac9F9b4777705db45291bbFF3c972c6d1d97](https://evm-explorer.alephzero.org/address/0x13fDac9F9b4777705db45291bbFF3c972c6d1d97) |
| MulticallHandler    | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://evm-explorer.alephzero.org/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Ink mainnet (57073)

| Contract Name    | Address                                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Ink_SpokePool    | [0xeF684C38F94F48775959ECf2012D7E864ffb9dd4](https://explorer.inkonchain.com/address/0xeF684C38F94F48775959ECf2012D7E864ffb9dd4) |
| MulticallHandler | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://explorer.inkonchain.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Soneium mainnet (1868)

| Contract Name     | Address                                                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Soneium_SpokePool | [0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96](https://soneium.blockscout.com/address/0x3baD7AD0728f9917d1Bf08af5782dCbD516cDd96) |
| MulticallHandler  | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://soneium.blockscout.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Unichain mainnet (130)

| Contract Name      | Address                                                                                                                          |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Unichain_SpokePool | [0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64](https://unichain.blockscout.com/address/0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64) |
| MulticallHandler   | [0x924a9f036260DdD5808007E1AA95f08eD08aA569](https://unichain.blockscout.com/address/0x924a9f036260DdD5808007E1AA95f08eD08aA569) |

## Lens mainnet (232)

| Contract Name    | Address                                        |
| ---------------- | ---------------------------------------------- |
| Lens_SpokePool   | [0xe7cb3e167e7475dE1331Cf6E0CEb187654619E12]() |
| MulticallHandler | [0xc5939F59b3c9662377DdA53A08D5085b2d52b719]() |
