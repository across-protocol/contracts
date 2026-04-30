// Stub declarations for hardhat types required by the transitive hardhat-deploy dependency.
// hardhat itself has been removed from this project.

declare module "hardhat/types/runtime" {}
declare module "hardhat/types/config" {}
declare module "hardhat/types" {
  export type LinkReferences = Record<string, Record<string, { length: number; start: number }[]>>;
  export interface Artifact {
    _format: string;
    contractName: string;
    sourceName: string;
    abi: unknown[];
    bytecode: string;
    deployedBytecode: string;
    linkReferences: LinkReferences;
    deployedLinkReferences: LinkReferences;
  }
  export interface HardhatRuntimeEnvironment {
    [key: string]: unknown;
  }
}
