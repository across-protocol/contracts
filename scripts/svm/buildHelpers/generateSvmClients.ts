import { createFromRoot } from "codama";
import { rootNodeFromAnchor, AnchorIdl } from "@codama/nodes-from-anchor";
import { renderVisitor as renderJavaScriptVisitor } from "@codama/renderers-js";
import {
  SvmSpokeIdl,
  MulticallHandlerIdl,
  MessageTransmitterIdl,
  TokenMessengerMinterIdl,
  MessageTransmitterV2Idl,
  TokenMessengerMinterV2Idl,
} from "../../../src/svm/assets";
import path from "path";
export const clientsPath = path.join(__dirname, "..", "..", "..", "src", "svm", "clients");

// Generate SvmSpoke clients
let codama = createFromRoot(rootNodeFromAnchor(SvmSpokeIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "SvmSpoke")));

// Generate MulticallHandler clients
codama = createFromRoot(rootNodeFromAnchor(MulticallHandlerIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "MulticallHandler")));

codama = createFromRoot(rootNodeFromAnchor(MessageTransmitterIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "MessageTransmitter")));

codama = createFromRoot(rootNodeFromAnchor(TokenMessengerMinterIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "TokenMessengerMinter")));

codama = createFromRoot(rootNodeFromAnchor(MessageTransmitterV2Idl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "MessageTransmitterV2")));

codama = createFromRoot(rootNodeFromAnchor(TokenMessengerMinterV2Idl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "TokenMessengerMinterV2")));
