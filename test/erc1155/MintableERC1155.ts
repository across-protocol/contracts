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

    it("revert if not called by owner", async () => {
      await expect(mintableErc1155.connect(otherAccount1).airdrop(tokenId, recipients, 1)).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
    });

    it("mint token to recipients", async () => {
      expect(await mintableErc1155.connect(contractCreator).airdrop(tokenId, recipients, 1))
        .to.emit(mintableErc1155, "Airdrop")
        .withArgs(contractCreator.address, tokenId, recipients, 1);

      expect(await mintableErc1155.balanceOf(otherAccount1.address, tokenId)).to.equal(1);
      expect(await mintableErc1155.balanceOf(otherAccount2.address, tokenId)).to.equal(1);
    });
  });

  describe("#setTokenURI() + #uri()", () => {
    it("revert if not called by owner", async () => {
      await expect(mintableErc1155.connect(otherAccount1).setTokenURI(0, "uri")).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
    });

    it("set token uri", async () => {
      await mintableErc1155.connect(contractCreator).setTokenURI(0, "test");
      expect(await mintableErc1155.uri(0)).to.equal("test");
    });
  });
});
