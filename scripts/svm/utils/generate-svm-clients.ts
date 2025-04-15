import { AnchorIdl, rootNodeFromAnchor } from "@codama/nodes-from-anchor";
import { renderVisitor as renderJavaScriptVisitor } from "@codama/renderers-js";
import { bottomUpTransformerVisitor } from "@codama/visitors";
import { createFromRoot, numberTypeNode } from "codama";
import path from "path";
import { MulticallHandlerIdl, SvmSpokeIdl } from "../../../src/svm/assets";
export const clientsPath = path.join(__dirname, "..", "..", "..", "src", "svm", "clients");

const transformDepositIdsVisitor = bottomUpTransformerVisitor([
  {
    select: (nodePath) => {
      const lastNode = nodePath[nodePath.length - 1];
      if (lastNode.kind !== "bytesTypeNode") return false;
      function containsFieldName(node: any, targetName: string): boolean {
        if (node?.name?.toLowerCase() === targetName.toLowerCase()) return true;
        return false;
      }
      return nodePath.some((node) => containsFieldName(node, "depositId"));
    },
    transform: () => numberTypeNode("u64"),
  },
]);

// Generate SvmSpoke clients
let codama = createFromRoot(rootNodeFromAnchor(SvmSpokeIdl as AnchorIdl));
codama.update(transformDepositIdsVisitor);
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "SvmSpoke")));

// Generate MulticallHandler clients
codama = createFromRoot(rootNodeFromAnchor(MulticallHandlerIdl as AnchorIdl));
codama.accept(renderJavaScriptVisitor(path.join(clientsPath, "MulticallHandler")));

// codama = createFromRoot(rootNodeFromAnchor(MessageTransmitterIdl as AnchorIdl));
// codama.accept(
//     renderJavaScriptVisitor(path.join(clientsPath, "MessageTransmitter"))
// );

// codama = createFromRoot(rootNodeFromAnchor(TokenMessengerMinterIdl as AnchorIdl));
// codama.accept(
//     renderJavaScriptVisitor(path.join(clientsPath, "TokenMessengerMinter"))
// );
