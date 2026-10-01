// Test-only SVM V5 conformance encoders. Not a production order builder.
import { PublicKey } from "@solana/web3.js";
import { createHash } from "crypto";
import { ethers } from "ethers";
export const u16 = (n: number) => {
  const b = Buffer.alloc(2);
  b.writeUInt16LE(n);
  return b;
};
export const u32 = (n: number) => {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n);
  return b;
};
export const u64 = (n: bigint | number | { toString(): string }) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(n.toString()));
  return b;
};
export const word = (n: bigint | number) =>
  Buffer.from(ethers.utils.zeroPad(ethers.BigNumber.from(n.toString()).toHexString(), 32));
export const vec = (b: Buffer) => Buffer.concat([u32(b.length), b]);

export const GATEWAY = new PublicKey("pVs6PJ3ofdqPyDhCXXdVW7waG6oNnwKQBKtuM6Mi6JP");
export const PREFUNDED = new PublicKey("8kUXfjTu6EUR1YLo962Nr2V66DfS4mcNKRKgSxgmipPJ");
export const GATEWAY_COMMIT = "e2b91eb0454136773728f941b33163346e039aa4";
export const PREFIX = Buffer.from("89ae4bc75915265a3f10e926c3894a29534f1d6362ee8959cb0e5be00f3527fd", "hex");
export const OP = {
  BALANCE_REQ: 0x00,
  CALL: 0x08,
  ADAPTER_CALL: 0x0a,
  PLAN_FROM_JIT: 0x0d,
  PLAN_FROM_PLANNER: 0x0e,
  APPROVE: 0x10,
  TRANSFER: 0x11,
  JIT: 0x40,
  OPTIONAL: 0x80,
};
export const discriminator = (name: string) => createHash("sha256").update(`global:${name}`).digest().subarray(0, 8);
export const list = (items: Buffer[]) => Buffer.concat([u32(items.length), ...items]);
export const hash = (b: Buffer) => Buffer.from(ethers.utils.arrayify(ethers.utils.keccak256(b)));
export const pda = (program: PublicKey, ...seeds: Buffer[]) => PublicKey.findProgramAddressSync(seeds, program)[0];
export type Meta = { pubkey: PublicKey; flags: number };
export const meta = (pubkey: PublicKey, writable = false): Meta => ({ pubkey, flags: Number(writable) });
export const injected = (): Meta => ({ pubkey: PublicKey.default, flags: 5 });
export type Command = { op: number; input: Buffer };
export const tape = (commands: Command[]) =>
  Buffer.concat([vec(Buffer.from(commands.map((c) => c.op))), list(commands.map((c) => vec(c.input)))]);
export const jitQueue = (items: Buffer[]) => list(items.map(vec));
export const call = (program: PublicKey, metas: Meta[], input: Buffer, balanceSubs: Buffer[] = []): Buffer =>
  Buffer.concat([
    program.toBuffer(),
    list(metas.map((m) => Buffer.concat([m.pubkey.toBuffer(), Buffer.from([m.flags])]))),
    vec(input),
    list(balanceSubs),
  ]);
export const approve = (mint: PublicKey, delegate: PublicKey): Command => ({
  op: OP.APPROVE,
  input: Buffer.concat([mint.toBuffer(), delegate.toBuffer(), u64(0xffffffffffffffffn), u16(10000)]),
});
export const floor = (mint: PublicKey, amount: bigint): Command => ({
  op: OP.BALANCE_REQ,
  input: Buffer.concat([mint.toBuffer(), u64(amount)]),
});
export const transfer = (mint: PublicKey, to: PublicKey, amount?: bigint): Command => ({
  op: OP.TRANSFER,
  input: Buffer.concat([
    mint.toBuffer(),
    to.toBuffer(),
    u64(amount ?? 0xffffffffffffffffn),
    u16(amount === undefined ? 10000 : 0),
  ]),
});
export type Path = { chainId: bigint; salt: Buffer; message: Buffer };
export const pathId = (p: Path) => hash(Buffer.concat([word(p.chainId), p.salt, GATEWAY.toBuffer(), hash(p.message)]));
// AuthorityRequirementPlanner's raw digest: domain, live path, plan slot and child tape.
export const authorityPlanDigest = (p: Path, planId: number, payload: Buffer) => {
  const domain = hash(Buffer.concat([hash(Buffer.from("ACXV.AuthorityRequirementPlanner.V1")), GATEWAY.toBuffer()]));
  return hash(Buffer.concat([domain, pathId(p), word(BigInt(planId)), hash(payload)]));
};
export const pair = (a: Buffer, b: Buffer) => hash(Buffer.concat(Buffer.compare(a, b) < 0 ? [a, b] : [b, a]));
export const executeParams = (path: Path, root: Buffer, proof: Buffer[], jit: Buffer[], funding: Buffer[]) =>
  Buffer.concat([
    root,
    u64(path.chainId),
    path.salt,
    GATEWAY.toBuffer(),
    vec(path.message),
    list(proof),
    vec(jitQueue(jit)),
    list(funding),
  ]);
export const funding = (source: PublicKey, mint: PublicKey, amount: bigint, deadline?: bigint) =>
  Buffer.concat([
    Buffer.from([deadline === undefined ? 1 : 7]),
    source.toBuffer(),
    mint.toBuffer(),
    u64(amount),
    deadline === undefined ? Buffer.from([0]) : u64(deadline),
  ]);

/** Only the simple canonical template: approve one fill, clear its allowance, a post-fill floor, then full
 * balance transfer. Arbitrary action/planner/aggregate paths need a separate
 * proof over ALL reachable outcomes and allowed JIT, not a check of one quote. */
export function canonicalInPlace(
  fill: Command,
  mint: PublicKey,
  delegate: PublicKey,
  minimum: bigint,
  recipient: PublicKey
): Command[] {
  if (fill.op !== (OP.ADAPTER_CALL | OP.JIT)) throw new Error("mandatory fill required");
  return [approve(mint, delegate), fill, approve(mint, delegate, 0n), floor(mint, minimum), transfer(mint, recipient)];
}

/** Accounting oracle for a concrete execution, not authentication of JIT or a
 * proof that a committed root is safe for every execution. */
export function assertAggregateDelivery(amounts: bigint[], delivered: bigint): void {
  if (delivered < amounts.reduce((sum, amount) => sum + amount, 0n)) throw new Error("aggregate underdelivery");
}
