import { createFromRoot } from "codama";
import { rootNodeFromAnchor, AnchorIdl } from "@codama/nodes-from-anchor";
import { renderVisitor as renderJavaScriptVisitor } from "@codama/renderers-js";
import {
  SvmSpokeIdl,
  MulticallHandlerIdl,
  MessageTransmitterV2Idl,
  TokenMessengerMinterV2Idl,
  SponsoredCctpSrcPeripheryIdl,
} from "../../../src/svm/assets";
import path from "path";
import { rmSync } from "fs";
export const clientsPath = path.join(__dirname, "..", "..", "..", "src", "svm", "clients");

// Remove obsolete generated clients from workspaces built before the V2 migration.
for (const name of ["MessageTransmitter", "TokenMessengerMinter"])
  rmSync(path.join(clientsPath, name), { recursive: true, force: true });

// Generate SvmSpoke clients
let codama = createFromRoot(rootNodeFromAnchor(SvmSpokeIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "SvmSpoke")));

// Generate MulticallHandler clients
codama = createFromRoot(rootNodeFromAnchor(MulticallHandlerIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "MulticallHandler")));

codama = createFromRoot(rootNodeFromAnchor(MessageTransmitterV2Idl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "MessageTransmitterV2")));

codama = createFromRoot(rootNodeFromAnchor(TokenMessengerMinterV2Idl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "TokenMessengerMinterV2")));

codama = createFromRoot(rootNodeFromAnchor(SponsoredCctpSrcPeripheryIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "SponsoredCctpSrcPeriphery")));
