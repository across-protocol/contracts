import { Idl, Program, AnchorProvider } from "@coral-xyz/anchor";
import { getSolanaChainId, isSolanaDevnet } from "../../scripts/svm/utils/helpers";
import { getDeployedAddress } from "../DeploymentUtils";
import { SupportedNetworks } from "../types/svm";
import {
  MessageTransmitterAnchor,
  MessageTransmitterIdl,
  MulticallHandlerAnchor,
  MulticallHandlerIdl,
  SvmSpokeAnchor,
  SvmSpokeIdl,
  TokenMessengerMinterAnchor,
  TokenMessengerMinterIdl,
} from "./assets";

type ProgramOptions = { network?: SupportedNetworks; programId?: string };

export function getConnectedProgram<P extends Idl>(idl: P, provider: AnchorProvider, programId: string) {
  idl.address = programId;
  return new Program<P>(idl, provider);
}

// Resolves the program ID from options or defaults to the deployed address. Prioritizes programId, falls back to
// network, and if network is not defined, determines the network from the provider's RPC URL. Throws an error if
// the program ID cannot be resolved.
function resolveProgramId(programName: string, provider: AnchorProvider, options?: ProgramOptions): string {
  const { network, programId } = options ?? {};

  if (programId) {
    return programId; // Prioritize explicitly provided programId
  }

  const resolvedNetwork = network ?? (isSolanaDevnet(provider) ? "devnet" : "mainnet");
  const deployedAddress = getDeployedAddress(programName, getSolanaChainId(resolvedNetwork).toString());

  if (!deployedAddress) {
    throw new Error(`${programName} Program ID not found for ${resolvedNetwork}`);
  }

  return deployedAddress;
}

export function getSpokePoolProgram(provider: AnchorProvider, options?: ProgramOptions) {
  const id = resolveProgramId("SvmSpoke", provider, options);
  return getConnectedProgram<SvmSpokeAnchor>(SvmSpokeIdl, provider, id);
}

export function getMessageTransmitterProgram(provider: AnchorProvider, options?: ProgramOptions) {
  const id = resolveProgramId("MessageTransmitter", provider, options);
  return getConnectedProgram<MessageTransmitterAnchor>(MessageTransmitterIdl, provider, id);
}

export function getTokenMessengerMinterProgram(provider: AnchorProvider, options?: ProgramOptions) {
  const id = resolveProgramId("TokenMessengerMinter", provider, options);
  return getConnectedProgram<TokenMessengerMinterAnchor>(TokenMessengerMinterIdl, provider, id);
}

export function getMulticallHandlerProgram(provider: AnchorProvider, options?: ProgramOptions) {
  const id = resolveProgramId("MulticallHandler", provider, options);
  return getConnectedProgram<MulticallHandlerAnchor>(MulticallHandlerIdl, provider, id);
}
