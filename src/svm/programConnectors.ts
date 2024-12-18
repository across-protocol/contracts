import { Idl, Program, Provider } from "@coral-xyz/anchor";
import {
  SvmSpokeIdl,
  SvmSpokeAnchor,
  MessageTransmitterAnchor,
  MessageTransmitterIdl,
  TokenMessengerMinterAnchor,
  TokenMessengerMinterIdl,
  MulticallHandlerAnchor,
  MulticallHandlerIdl,
} from "./assets";

export function getConnectedProgram<P extends Idl>(idl: P, provider: Provider) {
  return new Program<P>(idl, provider);
}

export function getSpokePoolProgram(provider: Provider) {
  return getConnectedProgram<SvmSpokeAnchor>(SvmSpokeIdl, provider);
}

export function getMessageTransmitterProgram(provider: Provider) {
  return getConnectedProgram<MessageTransmitterAnchor>(MessageTransmitterIdl, provider);
}

export function getTokenMessengerMinterProgram(provider: Provider) {
  return getConnectedProgram<TokenMessengerMinterAnchor>(TokenMessengerMinterIdl, provider);
}

export function getMulticallHandlerProgram(provider: Provider) {
  return getConnectedProgram<MulticallHandlerAnchor>(MulticallHandlerIdl, provider);
}
