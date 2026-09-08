import { assert } from "chai";
import { PublicKey } from "@solana/web3.js";
import fixture from "../../programs/svm-spoke/fixtures/v5_gateway_path.json";
import { GATEWAY_COMMIT, PREFIX, floor, pair, pathId, tape, transfer } from "./reference";

describe("Gateway path cross-VM vectors", () => {
  it("pins Borsh tape, EVM path hashing, sorted sibling root and V5 witness", () => {
    const bytes = (s: string) => Buffer.from(s.slice(2), "hex");
    const mint = new PublicKey(bytes(fixture.mint));
    const message = tape([
      floor(mint, BigInt(fixture.minimum)),
      transfer(mint, new PublicKey(bytes(fixture.recipient))),
    ]);
    assert.deepEqual(message, bytes(fixture.message));
    assert.equal(GATEWAY_COMMIT, fixture.gatewayCommit);
    const a = pathId({ chainId: BigInt(fixture.chainId), salt: bytes(fixture.salt), message });
    const b = pathId({ chainId: BigInt(fixture.chainId), salt: bytes(fixture.siblingSalt), message });
    assert.deepEqual(a, bytes(fixture.pathId));
    assert.deepEqual(b, bytes(fixture.siblingPathId));
    assert.deepEqual(pair(a, b), bytes(fixture.stepRoot));
    assert.deepEqual(pair(b, a), bytes(fixture.stepRoot));
    assert.deepEqual(Buffer.concat([PREFIX, pair(a, b)]), bytes(fixture.witness));
  });
});
