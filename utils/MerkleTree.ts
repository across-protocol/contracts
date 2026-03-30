// Inlined from @uma/common MerkleTree. Based on the Uniswap merkle-distributor implementation:
// https://github.com/Uniswap/merkle-distributor/blob/master/src/merkle-tree.ts
import { hexlify } from "@ethersproject/bytes";
import { keccak256 as keccak256Fn } from "@ethersproject/keccak256";

export const EMPTY_MERKLE_ROOT = "0x0000000000000000000000000000000000000000000000000000000000000000";

const bufferToHex = (buf: Buffer): string => hexlify(buf);
const keccak256 = (buf: Buffer): Buffer => Buffer.from(keccak256Fn(buf).slice(2), "hex");

export class MerkleTree<T> {
  private readonly elements: Buffer[];
  private readonly bufferElementPositionIndex: { [hexElement: string]: number };
  private readonly layers: Buffer[][];

  constructor(
    leaves: T[],
    readonly hashFn: (element: T) => string
  ) {
    this.elements = leaves.map((leaf) => this.leafToBuf(leaf));
    this.elements.sort(Buffer.compare);
    this.elements = MerkleTree.bufDedup(this.elements);

    this.bufferElementPositionIndex = this.elements.reduce<{ [hex: string]: number }>((memo, el, index) => {
      memo[bufferToHex(el)] = index;
      return memo;
    }, {});

    this.layers = this.getLayers(this.elements);
  }

  isEmpty(): boolean {
    return this.layers.length === 0;
  }

  getLayers(elements: Buffer[]): Buffer[][] {
    const layers: Buffer[][] = [];
    if (elements.length === 0) return layers;
    layers.push(elements);
    while (layers[layers.length - 1].length > 1) {
      layers.push(this.getNextLayer(layers[layers.length - 1]));
    }
    return layers;
  }

  getNextLayer(elements: Buffer[]): Buffer[] {
    return elements.reduce<Buffer[]>((layer, el, idx, arr) => {
      if (idx % 2 === 0) layer.push(MerkleTree.combinedHash(el, arr[idx + 1]));
      return layer;
    }, []);
  }

  static combinedHash(first: Buffer, second: Buffer): Buffer {
    if (!first) return second;
    if (!second) return first;
    return keccak256(MerkleTree.sortAndConcat(first, second));
  }

  getRoot(): Buffer {
    return this.layers[this.layers.length - 1][0];
  }

  getHexRoot(): string {
    if (this.isEmpty()) return EMPTY_MERKLE_ROOT;
    return bufferToHex(this.getRoot());
  }

  getProof(leaf: T): Buffer[] {
    return this.getProofRawBuf(this.leafToBuf(leaf));
  }

  getHexProof(leaf: T): string[] {
    return this.getHexProofRawBuf(this.leafToBuf(leaf));
  }

  leafToBuf(element: T): Buffer {
    const hash = this.hashFn(element);
    const hexString = hash.startsWith("0x") ? hash.substring(2) : hash;
    return Buffer.from(hexString.toLowerCase(), "hex");
  }

  getProofRawBuf(element: Buffer): Buffer[] {
    let idx = this.bufferElementPositionIndex[bufferToHex(element)];
    if (typeof idx !== "number") throw new Error("Element does not exist in Merkle tree");
    return this.layers.reduce<Buffer[]>((proof, layer) => {
      const pairElement = MerkleTree.getPairElement(idx, layer);
      if (pairElement) proof.push(pairElement);
      idx = Math.floor(idx / 2);
      return proof;
    }, []);
  }

  getHexProofRawBuf(el: Buffer): string[] {
    const proof = this.getProofRawBuf(el);
    return MerkleTree.bufArrToHexArr(proof);
  }

  private static getPairElement(idx: number, layer: Buffer[]): Buffer | null {
    const pairIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
    return pairIdx < layer.length ? layer[pairIdx] : null;
  }

  private static bufDedup(elements: Buffer[]): Buffer[] {
    return elements.filter((el, idx) => idx === 0 || !elements[idx - 1].equals(el));
  }

  private static bufArrToHexArr(arr: Buffer[]): string[] {
    if (arr.some((el) => !Buffer.isBuffer(el))) throw new Error("Array is not an array of buffers");
    return arr.map((el) => "0x" + el.toString("hex"));
  }

  private static sortAndConcat(...args: Buffer[]): Buffer {
    return Buffer.concat([...args].sort(Buffer.compare));
  }
}
