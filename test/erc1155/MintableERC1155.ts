import { ethers, getContractFactory, SignerWithAddress, Contract, expect } from "../utils";

let mintableErc1155: Contract;

let accounts: SignerWithAddress[];
let contractCreator: SignerWithAddress;
let otherAccount1: SignerWithAddress;
let otherAccount2: SignerWithAddress;
let recipients: string[];

describe("MintableERC1155", () => {
  beforeEach(async () => {
    accounts = await ethers.getSigners();
    [contractCreator, otherAccount1, otherAccount2] = accounts;
    recipients = [otherAccount1.address, otherAccount2.address];
    mintableErc1155 = await (await getContractFactory("MintableERC1155", contractCreator)).deploy();
  });

  describe("#airdrop()", () => {
    const tokenId = 0;
    const amounts = [1, 2];

    it("revert if not called by minter role", async () => {
      await expect(mintableErc1155.connect(otherAccount1).airdrop(tokenId, recipients, amounts)).to.be.revertedWith(
        "ERC1155PresetMinterPauser: must have minter role to mint"
      );
    });

    it("revert if recipients length mismatch amounts", async () => {
      await expect(mintableErc1155.connect(contractCreator).airdrop(tokenId, recipients, [1])).to.be.revertedWith(
        "MintableERC1155: recipients and amounts length mismatch"
      );
    });

    it("mint token to recipients", async () => {
      expect(await mintableErc1155.connect(contractCreator).airdrop(tokenId, recipients, amounts))
        .to.emit(mintableErc1155, "Airdrop")
        .withArgs(contractCreator.address, tokenId, recipients, amounts);

      expect(await mintableErc1155.balanceOf(otherAccount1.address, tokenId)).to.equal(amounts[0]);
      expect(await mintableErc1155.balanceOf(otherAccount2.address, tokenId)).to.equal(amounts[1]);
    });
  });

  describe("#setTokenURI() + #uri()", () => {
    it("revert if not called by minter role", async () => {
      await expect(mintableErc1155.connect(otherAccount1).setTokenURI(0, "uri")).to.be.revertedWith(
        "ERC1155PresetMinterPauser: must have minter role to set uri"
      );
    });

    it("set token uri", async () => {
      await mintableErc1155.connect(contractCreator).setTokenURI(0, "test");
      expect(await mintableErc1155.uri(0)).to.equal("test");
    });
  });
});
