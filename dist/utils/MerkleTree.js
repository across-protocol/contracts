"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.MerkleTree = void 0;
// This script provides some useful methods for building MerkleTrees. It is essentially the uniswap implementation
// https://github.com/Uniswap/merkle-distributor/blob/master/src/merkle-tree.ts with some added convenience methods
// to take the leaves and conversion functions, so the user never has to work with buffers.
const ethereumjs_util_1 = require("ethereumjs-util");
class MerkleTree {
  constructor(leaves, hashFn) {
    this.hashFn = hashFn;
    this.elements = leaves.map((leaf) => this.leafToBuf(leaf));
    // Sort elements
    this.elements.sort(Buffer.compare);
    // Deduplicate elements
    this.elements = MerkleTree.bufDedup(this.elements);
    this.bufferElementPositionIndex = this.elements.reduce((memo, el, index) => {
      memo[(0, ethereumjs_util_1.bufferToHex)(el)] = index;
      return memo;
    }, {});
    // Create layers
    this.layers = this.getLayers(this.elements);
  }
  getLayers(elements) {
    if (elements.length === 0) {
      throw new Error("empty tree");
    }
    const layers = [];
    layers.push(elements);
    // Get next layer until we reach the root
    while (layers[layers.length - 1].length > 1) {
      layers.push(this.getNextLayer(layers[layers.length - 1]));
    }
    return layers;
  }
  getNextLayer(elements) {
    return elements.reduce((layer, el, idx, arr) => {
      if (idx % 2 === 0) {
        // Hash the current element with its pair element
        layer.push(MerkleTree.combinedHash(el, arr[idx + 1]));
      }
      return layer;
    }, []);
  }
  static combinedHash(first, second) {
    if (!first) {
      return second;
    }
    if (!second) {
      return first;
    }
    return (0, ethereumjs_util_1.keccak256)(MerkleTree.sortAndConcat(first, second));
  }
  getRoot() {
    return this.layers[this.layers.length - 1][0];
  }
  getHexRoot() {
    return (0, ethereumjs_util_1.bufferToHex)(this.getRoot());
  }
  getProof(leaf) {
    return this.getProofRawBuf(this.leafToBuf(leaf));
  }
  getHexProof(leaf) {
    return this.getHexProofRawBuf(this.leafToBuf(leaf));
  }
  leafToBuf(element) {
    const hash = this.hashFn(element);
    const hexString = hash.startsWith("0x") ? hash.substring(2) : hash;
    return Buffer.from(hexString.toLowerCase(), "hex");
  }
  // Methods that take the raw buffers (hashes).
  getProofRawBuf(element) {
    let idx = this.bufferElementPositionIndex[(0, ethereumjs_util_1.bufferToHex)(element)];
    if (typeof idx !== "number") {
      throw new Error("Element does not exist in Merkle tree");
    }
    return this.layers.reduce((proof, layer) => {
      const pairElement = MerkleTree.getPairElement(idx, layer);
      if (pairElement) {
        proof.push(pairElement);
      }
      idx = Math.floor(idx / 2);
      return proof;
    }, []);
  }
  getHexProofRawBuf(el) {
    const proof = this.getProofRawBuf(el);
    return MerkleTree.bufArrToHexArr(proof);
  }
  static getPairElement(idx, layer) {
    const pairIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
    if (pairIdx < layer.length) {
      return layer[pairIdx];
    } else {
      return null;
    }
  }
  static bufDedup(elements) {
    return elements.filter((el, idx) => {
      return idx === 0 || !elements[idx - 1].equals(el);
    });
  }
  static bufArrToHexArr(arr) {
    if (arr.some((el) => !Buffer.isBuffer(el))) {
      throw new Error("Array is not an array of buffers");
    }
    return arr.map((el) => "0x" + el.toString("hex"));
  }
  static sortAndConcat(...args) {
    return Buffer.concat([...args].sort(Buffer.compare));
  }
}
exports.MerkleTree = MerkleTree;
