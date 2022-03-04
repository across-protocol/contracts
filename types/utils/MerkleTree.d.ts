/// <reference types="node" />
export declare class MerkleTree<T> {
  readonly hashFn: (element: T) => string;
  private readonly elements;
  private readonly bufferElementPositionIndex;
  private readonly layers;
  constructor(leaves: T[], hashFn: (element: T) => string);
  getLayers(elements: Buffer[]): Buffer[][];
  getNextLayer(elements: Buffer[]): Buffer[];
  static combinedHash(first: Buffer, second: Buffer): Buffer;
  getRoot(): Buffer;
  getHexRoot(): string;
  getProof(leaf: T): Buffer[];
  getHexProof(leaf: T): string[];
  leafToBuf(element: T): Buffer;
  getProofRawBuf(element: Buffer): Buffer[];
  getHexProofRawBuf(el: Buffer): string[];
  private static getPairElement;
  private static bufDedup;
  private static bufArrToHexArr;
  private static sortAndConcat;
}
