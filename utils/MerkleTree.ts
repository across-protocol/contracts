// The package `@uma/common` can not be tree-shaken and contains some modules that are not
// compatible with the browser. This is a temporary fix to avoid bundling the whole package
// until we can fix the issue upstream.
export { MerkleTree, EMPTY_MERKLE_ROOT } from "@uma/common/dist/MerkleTree";
