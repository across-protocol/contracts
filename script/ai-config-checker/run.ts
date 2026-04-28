#!/usr/bin/env ts-node

import * as fs from "fs";
import * as path from "path";
import { execFileSync } from "child_process";
import { BigNumber, Contract, ethers } from "ethers";

type Primitive = string | number | boolean | null;
type NormalizedValue = Primitive | Primitive[] | Record<string, Primitive>;

interface BroadcastTransaction {
  hash?: string;
  transactionType?: string;
  contractName?: string;
  contractAddress?: string;
  arguments?: unknown[];
}

interface BroadcastReceiptFile {
  transactions?: BroadcastTransaction[];
}

interface DeploymentTarget {
  address: string;
  artifactContractName: string | null;
  chainId: number;
  scriptName: string;
  sourcePath: string;
  transactionHash: string | null;
  transactionType: string | null;
  txArguments: unknown[];
  rawContractName: string | null;
}

interface ArtifactLike {
  abi?: Array<{
    type?: string;
    name?: string;
    stateMutability?: string;
    inputs?: Array<{ name?: string; type?: string }>;
    outputs?: Array<{ name?: string; type?: string }>;
  }>;
  devdoc?: {
    methods?: Record<string, { details?: string; notice?: string }>;
  };
  userdoc?: {
    methods?: Record<string, { notice?: string }>;
  };
}

interface CandidateGetter {
  name: string;
  signature: string;
  stateMutability: string;
  deterministicPriority: "must_check" | "candidate";
  whySelected: string;
  natspecNotice: string | null;
  natspecDetails: string | null;
}

interface EvidenceItem {
  kind: string;
  source: string;
  status: "match" | "mismatch" | "related" | "observed" | "unavailable";
  details: string;
  expected?: Primitive;
  actual?: Primitive;
}

interface GetterObservation {
  getter: CandidateGetter;
  callSucceeded: boolean;
  value: NormalizedValue | null;
  rawValue: string | null;
  error: string | null;
  deterministicEvidence: EvidenceItem[];
}

interface AIAssessment {
  variable_name: string;
  should_include: boolean;
  verdict: "correct" | "incorrect" | "uncertain";
  confidence: number;
  reasoning: string;
  evidence_refs: string[];
}

interface ContractReport {
  deployment: DeploymentTarget;
  implementationAddress: string | null;
  adminAddress: string | null;
  artifactPath: string | null;
  observations: GetterObservation[];
  assessments: AIAssessment[];
}

interface GitHubComment {
  id: number;
  body: string;
}

const COMMENT_MARKER = "<!-- deployment-config-checker -->";
const IMPLEMENTATION_SLOT = "0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC";
const ADMIN_SLOT = "0xB53127684A568B3173AE13B9F8A6016E243E63B6E8EE1178D6A717850B5D6103";
const MUST_CHECK_NAMES = new Set([
  "owner",
  "admin",
  "finder",
  "hubPool",
  "spokePool",
  "crossDomainAdmin",
  "wrappedNativeToken",
  "weth",
  "tokenMessenger",
  "messageTransmitter",
  "lineaMessageService",
  "lineaTokenBridge",
  "l1ArbitrumInbox",
  "l1ERC20GatewayRouter",
  "l1CrossDomainMessenger",
  "l1StandardBridge",
  "l1OpUSDCBridgeAdapter",
  "polygonRootChainManager",
  "polygonFxRoot",
  "polygonERC20Predicate",
  "polygonRegistry",
  "polygonDepositManager",
  "scrollERC20GatewayRouter",
  "scrollMessengerRelay",
  "scrollGasPriceOracle",
  "adapterStore",
  "donationBox",
  "hubPoolStore",
  "destinationDomain",
  "sourceDomain",
  "cctpDomain",
  "oftEid",
  "router",
  "bridge",
  "mailbox",
  "signer",
  "quoteSigner",
  "verifier",
  "sp1Helios",
]);
const CONFIG_NAME_HINTS = [
  "owner",
  "admin",
  "pool",
  "token",
  "wrapped",
  "messenger",
  "bridge",
  "router",
  "finder",
  "domain",
  "store",
  "adapter",
  "signer",
  "verifier",
  "factory",
  "mailbox",
  "endpoint",
];
const DENYLIST_PATTERNS = [
  /^VERSION$/,
  /^getCurrentTime$/,
  /^numberOf/i,
  /^rootBundle/i,
  /^relayRoot/i,
  /Timestamp$/,
  /Deadline$/,
  /^chainBalance/i,
  /Count$/,
  /Counter$/,
  /Nonce$/,
];

async function main() {
  const repoRoot = getGitRoot();
  const baseSha = mustGetEnv("DEPLOY_CONFIG_BASE_SHA");
  const headSha = mustGetEnv("DEPLOY_CONFIG_HEAD_SHA");
  const prNumber = parseInt(mustGetEnv("DEPLOY_CONFIG_PR_NUMBER"), 10);
  const repoFullName = mustGetEnv("GITHUB_REPOSITORY");
  const githubToken = mustGetEnv("GITHUB_TOKEN");
  const anthropicApiKey = mustGetEnv("ANTHROPIC_API_KEY");
  const anthropicModel = process.env.ANTHROPIC_MODEL || "claude-sonnet-4-20250514";

  const changedBroadcastFiles = getChangedBroadcastFiles(repoRoot, baseSha, headSha);
  if (changedBroadcastFiles.length === 0) {
    console.log("No changed broadcast receipts detected.");
    return;
  }

  const deployments = discoverNewDeployments(repoRoot, baseSha, changedBroadcastFiles);
  if (deployments.length === 0) {
    console.log("No new CREATE/CREATE2 deployments detected in changed broadcast receipts.");
    return;
  }

  const constants = readJson(path.join(repoRoot, "generated/constants.json"));
  const deployedAddresses = readJson(path.join(repoRoot, "broadcast/deployed-addresses.json"));
  const flattenedConstants = flattenReferenceValues(constants, "generated/constants.json");
  const flattenedDeployments = flattenDeployedAddressValues(deployedAddresses);
  const artifactIndex = indexArtifacts(path.join(repoRoot, "out"));
  const rpcUrlMap = readRpcUrlMap();

  const reports: ContractReport[] = [];
  for (const deployment of deployments) {
    reports.push(
      await analyzeDeployment({
        deployment,
        artifactIndex,
        constants,
        deployedAddresses,
        flattenedConstants,
        flattenedDeployments,
        rpcUrlMap,
      })
    );
  }

  for (const report of reports) {
    report.assessments = await assessWithClaude({
      report,
      anthropicApiKey,
      anthropicModel,
    });
  }

  const finalReport = {
    generated_at: new Date().toISOString(),
    base_sha: baseSha,
    head_sha: headSha,
    repository: repoFullName,
    pr_number: prNumber,
    deployments_checked: reports.length,
    reports,
  };
  fs.writeFileSync(
    path.join(repoRoot, "deployment-config-check-report.json"),
    JSON.stringify(finalReport, null, 2) + "\n"
  );

  upsertPullRequestComment({
    repoFullName,
    prNumber,
    githubToken,
    commentBody: renderComment(reports),
  });

  const shouldFail = reports
    .flatMap((report) => report.assessments)
    .some(
      (assessment) => assessment.should_include && assessment.verdict === "incorrect" && assessment.confidence >= 80
    );
  if (shouldFail) throw new Error("Deployment config checker found high-confidence incorrect configuration values.");
}

async function analyzeDeployment(params: {
  deployment: DeploymentTarget;
  artifactIndex: Map<string, string[]>;
  constants: Record<string, unknown>;
  deployedAddresses: Record<string, unknown>;
  flattenedConstants: Array<{ source: string; value: Primitive }>;
  flattenedDeployments: Array<{ source: string; value: Primitive }>;
  rpcUrlMap: Map<number, string>;
}): Promise<ContractReport> {
  const {
    deployment,
    artifactIndex,
    constants,
    deployedAddresses,
    flattenedConstants,
    flattenedDeployments,
    rpcUrlMap,
  } = params;
  const artifactPath = deployment.artifactContractName
    ? selectArtifactPath(artifactIndex.get(deployment.artifactContractName) || [], deployment.artifactContractName)
    : null;

  const rpcUrl = rpcUrlMap.get(deployment.chainId);
  if (!rpcUrl) {
    throw new Error(
      `Missing RPC URL for chain ${deployment.chainId}. Set DEPLOY_CONFIG_RPC_URLS_JSON or NODE_URL_${deployment.chainId}.`
    );
  }

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const implementationAddress = await readProxySlot(provider, deployment.address, IMPLEMENTATION_SLOT);
  const adminAddress = await readProxySlot(provider, deployment.address, ADMIN_SLOT);
  const artifact = artifactPath ? (readJson(artifactPath) as ArtifactLike) : null;
  const getters = artifact ? discoverCandidateGetters(artifact) : [];
  const contract = new Contract(deployment.address, artifact?.abi || [], provider);

  const observations = await Promise.all(
    getters.map((getter) =>
      observeGetter({
        getter,
        contract,
        deployment,
        constants,
        deployedAddresses,
        flattenedConstants,
        flattenedDeployments,
        implementationAddress,
        adminAddress,
      })
    )
  );

  return {
    deployment,
    implementationAddress,
    adminAddress,
    artifactPath,
    observations,
    assessments: [],
  };
}

async function observeGetter(params: {
  getter: CandidateGetter;
  contract: Contract;
  deployment: DeploymentTarget;
  constants: Record<string, unknown>;
  deployedAddresses: Record<string, unknown>;
  flattenedConstants: Array<{ source: string; value: Primitive }>;
  flattenedDeployments: Array<{ source: string; value: Primitive }>;
  implementationAddress: string | null;
  adminAddress: string | null;
}): Promise<GetterObservation> {
  const {
    getter,
    contract,
    deployment,
    constants,
    deployedAddresses,
    flattenedConstants,
    flattenedDeployments,
    implementationAddress,
    adminAddress,
  } = params;

  try {
    const raw = await contract.functions[getter.name]();
    const value = Array.isArray(raw) && raw.length === 1 ? raw[0] : raw;
    const normalized = normalizeValue(value);
    return {
      getter,
      callSucceeded: true,
      value: normalized,
      rawValue: stringifyValue(value),
      error: null,
      deterministicEvidence: buildDeterministicEvidence({
        getter,
        normalized,
        deployment,
        constants,
        deployedAddresses,
        flattenedConstants,
        flattenedDeployments,
        implementationAddress,
        adminAddress,
      }),
    };
  } catch (error) {
    return {
      getter,
      callSucceeded: false,
      value: null,
      rawValue: null,
      error: error instanceof Error ? error.message : String(error),
      deterministicEvidence: [
        {
          kind: "call_error",
          source: "onchain",
          status: "unavailable",
          details: error instanceof Error ? error.message : String(error),
        },
      ],
    };
  }
}

function discoverCandidateGetters(artifact: ArtifactLike): CandidateGetter[] {
  const candidates: CandidateGetter[] = [];
  for (const method of artifact.abi || []) {
    if (method.type !== "function" || !method.name) continue;
    const inputs = method.inputs || [];
    const outputs = method.outputs || [];
    const stateMutability = method.stateMutability || "";
    if (!["view", "pure"].includes(stateMutability) || inputs.length !== 0 || outputs.length === 0) continue;
    if (DENYLIST_PATTERNS.some((pattern) => pattern.test(method.name))) continue;
    if (!outputs.every((output) => isSupportedOutputType(output.type || ""))) continue;

    const loweredName = method.name.toLowerCase();
    const mustCheck = MUST_CHECK_NAMES.has(method.name);
    const candidate = mustCheck || CONFIG_NAME_HINTS.some((hint) => loweredName.includes(hint));
    if (!candidate) continue;

    const signature = `${method.name}()`;
    const natspecKey = findNatspecKey(artifact, signature);
    candidates.push({
      name: method.name,
      signature,
      stateMutability,
      deterministicPriority: mustCheck ? "must_check" : "candidate",
      whySelected: mustCheck
        ? "Matched deterministic must-check getter name."
        : "Matched deterministic config-related naming heuristic.",
      natspecNotice: natspecKey
        ? artifact.userdoc?.methods?.[natspecKey]?.notice || artifact.devdoc?.methods?.[natspecKey]?.notice || null
        : null,
      natspecDetails: natspecKey ? artifact.devdoc?.methods?.[natspecKey]?.details || null : null,
    });
  }
  return candidates.sort((left, right) => left.name.localeCompare(right.name));
}

function buildDeterministicEvidence(params: {
  getter: CandidateGetter;
  normalized: NormalizedValue;
  deployment: DeploymentTarget;
  constants: Record<string, unknown>;
  deployedAddresses: Record<string, unknown>;
  flattenedConstants: Array<{ source: string; value: Primitive }>;
  flattenedDeployments: Array<{ source: string; value: Primitive }>;
  implementationAddress: string | null;
  adminAddress: string | null;
}): EvidenceItem[] {
  const {
    getter,
    normalized,
    deployment,
    constants,
    deployedAddresses,
    flattenedConstants,
    flattenedDeployments,
    implementationAddress,
    adminAddress,
  } = params;

  const evidence: EvidenceItem[] = [
    {
      kind: "selection_reason",
      source: "deterministic-discovery",
      status: "observed",
      details: getter.whySelected,
    },
  ];

  if (!isPrimitive(normalized)) return evidence;

  for (const match of flattenedConstants.filter((entry) => primitiveEqual(entry.value, normalized)).slice(0, 5)) {
    evidence.push({
      kind: "constant_reference",
      source: match.source,
      status: "related",
      details: `Observed value matches a generated constant reference at ${match.source}.`,
      actual: normalized,
    });
  }

  for (const match of flattenedDeployments.filter((entry) => primitiveEqual(entry.value, normalized)).slice(0, 5)) {
    evidence.push({
      kind: "deployed_address_reference",
      source: match.source,
      status: "related",
      details: `Observed value matches a deployed contract address recorded at ${match.source}.`,
      actual: normalized,
    });
  }

  const expected = deriveExpectedValue(
    getter.name,
    deployment.chainId,
    constants,
    deployedAddresses,
    implementationAddress,
    adminAddress
  );
  if (expected !== undefined) {
    evidence.push({
      kind: "name_derived_expectation",
      source: "deterministic-rule",
      status: primitiveEqual(expected, normalized) ? "match" : "mismatch",
      details: `Deterministic expectation derived from getter name ${getter.name}.`,
      expected,
      actual: normalized,
    });
  }

  return evidence;
}

function deriveExpectedValue(
  getterName: string,
  chainId: number,
  constants: Record<string, unknown>,
  deployedAddresses: Record<string, unknown>,
  implementationAddress: string | null,
  adminAddress: string | null
): Primitive | undefined {
  const hubChainId = resolveHubChainId(chainId, constants);
  const l1AddressMap = getObjectPath(constants, ["L1_ADDRESS_MAP", String(hubChainId)]) as
    | Record<string, unknown>
    | undefined;
  const opStackAddressMap = getObjectPath(constants, ["OP_STACK_ADDRESS_MAP", String(hubChainId), String(chainId)]) as
    | Record<string, unknown>
    | undefined;
  const publicNetwork = getObjectPath(constants, ["PUBLIC_NETWORKS", String(chainId)]) as
    | Record<string, unknown>
    | undefined;

  switch (getterName) {
    case "chainId":
      return chainId;
    case "hubPool":
      return getDeployedAddress(deployedAddresses, hubChainId, "HubPool");
    case "spokePool":
      return getDeployedAddress(deployedAddresses, chainId, "SpokePool");
    case "wrappedNativeToken":
    case "weth":
      return asPrimitive(getObjectPath(constants, ["WRAPPED_NATIVE_TOKENS", String(chainId)]));
    case "finder":
    case "adapterStore":
    case "donationBox":
    case "hubPoolStore":
    case "lineaMessageService":
    case "lineaTokenBridge":
    case "polygonRootChainManager":
    case "polygonFxRoot":
    case "polygonERC20Predicate":
    case "polygonRegistry":
    case "polygonDepositManager":
    case "scrollERC20GatewayRouter":
    case "scrollMessengerRelay":
    case "scrollGasPriceOracle":
    case "l1ArbitrumInbox":
    case "l1ERC20GatewayRouter":
    case "cctpTokenMessenger":
    case "cctpV2TokenMessenger":
    case "cctpMessageTransmitter":
      return asPrimitive(l1AddressMap?.[getterName]);
    case "l1CrossDomainMessenger":
    case "l1StandardBridge":
    case "l1OpUSDCBridgeAdapter":
      return asPrimitive(opStackAddressMap?.[getterName]);
    case "cctpDomain":
    case "sourceDomain":
    case "destinationDomain":
      return asPrimitive(publicNetwork?.cctpDomain);
    case "oftEid":
      return asPrimitive(publicNetwork?.oftEid);
    case "implementation":
      return implementationAddress;
    case "admin":
      return adminAddress;
    default:
      return undefined;
  }
}

function getDeployedAddress(
  deployedAddresses: Record<string, unknown>,
  chainId: number,
  contractName: string
): Primitive | undefined {
  return asPrimitive(
    getObjectPath(deployedAddresses, ["chains", String(chainId), "contracts", contractName, "address"])
  );
}

async function assessWithClaude(params: {
  report: ContractReport;
  anthropicApiKey: string;
  anthropicModel: string;
}): Promise<AIAssessment[]> {
  const { report, anthropicApiKey, anthropicModel } = params;
  const payload = {
    contract_name: report.deployment.artifactContractName || report.deployment.rawContractName || "unknown",
    chain_id: report.deployment.chainId,
    deployment_address: report.deployment.address,
    implementation_address: report.implementationAddress,
    admin_address: report.adminAddress,
    observations: report.observations.map((observation) => ({
      variable_name: observation.getter.name,
      signature: observation.getter.signature,
      priority: observation.getter.deterministicPriority,
      natspec_notice: observation.getter.natspecNotice,
      natspec_details: observation.getter.natspecDetails,
      call_succeeded: observation.callSucceeded,
      value: observation.value,
      error: observation.error,
      deterministic_evidence: observation.deterministicEvidence,
    })),
  };

  const responseText = await callAnthropic(anthropicApiKey, {
    model: anthropicModel,
    max_tokens: 4000,
    system:
      "You review smart contract deployment configuration. Use getter names, NatSpec, deterministic evidence, and deployment context. Return strict JSON only.",
    messages: [
      {
        role: "user",
        content:
          `Review this contract deployment report.\n` +
          `Return a JSON array. Each element must contain variable_name, should_include, verdict, confidence, reasoning, evidence_refs.\n` +
          `Use verdict values only: correct, incorrect, uncertain.\n` +
          `should_include should be true when the getter is config-related enough to appear in the PR report.\n` +
          `confidence must be 0-100.\n` +
          `evidence_refs must be short strings referencing the strongest supporting evidence.\n\n` +
          JSON.stringify(payload, null, 2),
      },
    ],
  });
  const jsonText = extractJsonArray(responseText);
  const parsed = JSON.parse(jsonText) as AIAssessment[];
  return report.observations.map((observation) => {
    const assessment = parsed.find((entry) => entry.variable_name === observation.getter.name);
    return assessment
      ? sanitizeAssessment(assessment)
      : {
          variable_name: observation.getter.name,
          should_include: true,
          verdict: "uncertain",
          confidence: 0,
          reasoning: "Claude response did not include this getter.",
          evidence_refs: [],
        };
  });
}

async function callAnthropic(apiKey: string, body: Record<string, unknown>): Promise<string> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const parsed = (await response.json()) as {
    error?: { message?: string };
    content?: Array<{ type?: string; text?: string }>;
  };
  if (!response.ok) throw new Error(`Anthropic API error: ${parsed.error?.message || response.statusText}`);
  const text = parsed.content?.find((item) => item.type === "text")?.text;
  if (!text) throw new Error("Anthropic API response did not contain text content.");
  return text;
}

function sanitizeAssessment(assessment: AIAssessment): AIAssessment {
  return {
    variable_name: assessment.variable_name,
    should_include: Boolean(assessment.should_include),
    verdict: ["correct", "incorrect", "uncertain"].includes(assessment.verdict) ? assessment.verdict : "uncertain",
    confidence: Number.isFinite(assessment.confidence) ? Math.max(0, Math.min(100, assessment.confidence)) : 0,
    reasoning: assessment.reasoning || "",
    evidence_refs: Array.isArray(assessment.evidence_refs) ? assessment.evidence_refs.map(String) : [],
  };
}

function renderComment(reports: ContractReport[]): string {
  const summaryRows = reports.map((report) => {
    const included = report.assessments.filter((assessment) => assessment.should_include);
    return `| \`${report.deployment.artifactContractName || report.deployment.rawContractName || "unknown"}\` | \`${report.deployment.chainId}\` | \`${report.deployment.address}\` | ${included.length} | ${included.filter((item) => item.verdict === "incorrect").length} | ${included.filter((item) => item.verdict === "uncertain").length} |`;
  });

  const sections = reports.map((report) => {
    const includedMap = new Map(
      report.assessments
        .filter((assessment) => assessment.should_include)
        .map((assessment) => [assessment.variable_name, assessment])
    );
    const lines = [
      `### ${report.deployment.artifactContractName || report.deployment.rawContractName || "UnknownContract"} on chain ${report.deployment.chainId}`,
      "",
      `- Deployment: \`${report.deployment.address}\``,
      report.implementationAddress ? `- Implementation: \`${report.implementationAddress}\`` : "- Implementation: n/a",
      report.adminAddress ? `- Proxy admin: \`${report.adminAddress}\`` : "- Proxy admin: n/a",
      "",
      "| Variable | Value | Verdict | Confidence | Reasoning |",
      "| --- | --- | --- | --- | --- |",
    ];

    for (const observation of report.observations) {
      const assessment = includedMap.get(observation.getter.name);
      if (!assessment) continue;
      const renderedValue = observation.callSucceeded
        ? truncateForTable(JSON.stringify(observation.value))
        : `call failed: ${observation.error}`;
      lines.push(
        `| \`${observation.getter.name}\` | \`${escapePipes(renderedValue)}\` | ${assessment.verdict} | ${assessment.confidence} | ${escapePipes(
          truncateForTable(assessment.reasoning, 220)
        )} |`
      );
    }

    return lines.join("\n");
  });

  return [
    COMMENT_MARKER,
    "## Deployment Config Check",
    "",
    "This report was generated from newly added `broadcast/**/run-latest.json` deployment receipts in the PR.",
    "",
    "| Contract | Chain | Address | Checked | Incorrect | Uncertain |",
    "| --- | --- | --- | --- | --- | --- |",
    ...summaryRows,
    "",
    ...sections,
  ].join("\n");
}

function upsertPullRequestComment(params: {
  repoFullName: string;
  prNumber: number;
  githubToken: string;
  commentBody: string;
}) {
  const { repoFullName, prNumber, githubToken, commentBody } = params;
  const [owner, repo] = repoFullName.split("/");
  const comments = githubRequest<GitHubComment[]>(
    `https://api.github.com/repos/${owner}/${repo}/issues/${prNumber}/comments`,
    githubToken,
    "GET"
  );
  const existing = comments.find((comment) => comment.body?.includes(COMMENT_MARKER));

  if (existing) {
    githubRequest(
      `https://api.github.com/repos/${owner}/${repo}/issues/comments/${existing.id}`,
      githubToken,
      "PATCH",
      { body: commentBody }
    );
    return;
  }

  githubRequest(`https://api.github.com/repos/${owner}/${repo}/issues/${prNumber}/comments`, githubToken, "POST", {
    body: commentBody,
  });
}

function githubRequest<T>(url: string, token: string, method: string, body?: Record<string, unknown>): T {
  const args = [
    "-sS",
    url,
    "-X",
    method,
    "-H",
    `Authorization: Bearer ${token}`,
    "-H",
    "Accept: application/vnd.github+json",
  ];
  if (body) args.push("-H", "Content-Type: application/json", "-d", JSON.stringify(body));
  return JSON.parse(execFileSync("curl", args, { encoding: "utf8" })) as T;
}

function discoverNewDeployments(repoRoot: string, baseSha: string, changedFiles: string[]): DeploymentTarget[] {
  const deployments: DeploymentTarget[] = [];
  for (const filePath of changedFiles) {
    const headReceipt = readJson(path.join(repoRoot, filePath)) as BroadcastReceiptFile;
    const baseReceipt = readJsonFromGit(repoRoot, baseSha, filePath) as BroadcastReceiptFile | null;
    const existingAddresses = new Set(
      (baseReceipt?.transactions || [])
        .filter((tx) => ["CREATE", "CREATE2"].includes(tx.transactionType || "") && tx.contractAddress)
        .map((tx) => ethers.utils.getAddress(tx.contractAddress as string))
    );

    const scriptName = path.basename(path.dirname(path.dirname(filePath)));
    const chainId = parseInt(path.basename(path.dirname(filePath)), 10);
    for (const tx of headReceipt.transactions || []) {
      if (!["CREATE", "CREATE2"].includes(tx.transactionType || "") || !tx.contractAddress) continue;
      const address = ethers.utils.getAddress(tx.contractAddress);
      if (existingAddresses.has(address)) continue;
      deployments.push({
        address,
        artifactContractName: inferArtifactContractName(scriptName, tx.contractName || null),
        chainId,
        scriptName,
        sourcePath: filePath,
        transactionHash: tx.hash || null,
        transactionType: tx.transactionType || null,
        txArguments: Array.isArray(tx.arguments) ? tx.arguments : [],
        rawContractName: tx.contractName || null,
      });
    }
  }
  return deployments;
}

function inferArtifactContractName(scriptName: string, contractName: string | null): string | null {
  if (contractName && contractName !== "ERC1967Proxy") return contractName;
  const stripped = scriptName.replace(/^Deploy/i, "").replace(/\.s\.sol$/, "");
  if (stripped.endsWith("SpokePool")) return "SpokePool";
  if (stripped.endsWith("HubPool")) return "HubPool";
  if (stripped.length === 0) return null;
  return stripped;
}

function getChangedBroadcastFiles(repoRoot: string, baseSha: string, headSha: string): string[] {
  return execFileSync("git", ["diff", "--name-only", baseSha, headSha], { cwd: repoRoot, encoding: "utf8" })
    .trim()
    .split("\n")
    .filter(Boolean)
    .filter((filePath) => /^broadcast\/.+\/\d+\/run-latest\.json$/.test(filePath));
}

function readJson(filePath: string): Record<string, unknown> {
  return JSON.parse(fs.readFileSync(filePath, "utf8")) as Record<string, unknown>;
}

function readJsonFromGit(repoRoot: string, rev: string, filePath: string): Record<string, unknown> | null {
  try {
    return JSON.parse(
      execFileSync("git", ["show", `${rev}:${filePath}`], {
        cwd: repoRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      })
    ) as Record<string, unknown>;
  } catch {
    return null;
  }
}

function getGitRoot(): string {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
}

function indexArtifacts(outDir: string): Map<string, string[]> {
  if (!fs.existsSync(outDir)) {
    throw new Error("Foundry artifact directory `out/` is missing. Run `yarn build-evm-foundry` first.");
  }
  const index = new Map<string, string[]>();
  for (const filePath of walk(outDir)) {
    if (!filePath.endsWith(".json")) continue;
    const baseName = path.basename(filePath, ".json");
    const entries = index.get(baseName) || [];
    entries.push(filePath);
    index.set(baseName, entries);
  }
  return index;
}

function selectArtifactPath(paths: string[], contractName: string): string | null {
  if (paths.length === 0) return null;
  return paths.find((candidate) => candidate.endsWith(`/${contractName}.sol/${contractName}.json`)) || paths[0];
}

function walk(dirPath: string): string[] {
  const files: string[] = [];
  for (const entry of fs.readdirSync(dirPath, { withFileTypes: true })) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) files.push(...walk(fullPath));
    else files.push(fullPath);
  }
  return files;
}

function readRpcUrlMap(): Map<number, string> {
  const urls = new Map<number, string>();
  if (process.env.DEPLOY_CONFIG_RPC_URLS_JSON) {
    const parsed = JSON.parse(process.env.DEPLOY_CONFIG_RPC_URLS_JSON) as Record<string, string>;
    for (const [chainId, rpcUrl] of Object.entries(parsed)) {
      if (rpcUrl) urls.set(parseInt(chainId, 10), rpcUrl);
    }
  }
  for (const [key, value] of Object.entries(process.env)) {
    const match = key.match(/^NODE_URL_(\d+)$/);
    if (match && value) urls.set(parseInt(match[1], 10), value);
  }
  return urls;
}

async function readProxySlot(
  provider: ethers.providers.JsonRpcProvider,
  address: string,
  slot: string
): Promise<string | null> {
  try {
    const raw = await provider.getStorageAt(address, slot);
    if (!raw || /^0x0+$/.test(raw)) return null;
    return ethers.utils.getAddress("0x" + raw.slice(-40));
  } catch {
    return null;
  }
}

function flattenReferenceValues(
  input: unknown,
  source: string,
  currentPath = source,
  output: Array<{ source: string; value: Primitive }> = []
): Array<{ source: string; value: Primitive }> {
  if (isPrimitive(input)) {
    output.push({ source: currentPath, value: normalizePrimitive(input) });
    return output;
  }
  if (Array.isArray(input)) {
    input.forEach((value, index) => flattenReferenceValues(value, source, `${currentPath}[${index}]`, output));
    return output;
  }
  if (input && typeof input === "object") {
    for (const [key, value] of Object.entries(input)) {
      flattenReferenceValues(value, source, `${currentPath}.${key}`, output);
    }
  }
  return output;
}

function flattenDeployedAddressValues(input: Record<string, unknown>): Array<{ source: string; value: Primitive }> {
  return flattenReferenceValues(input, "broadcast/deployed-addresses.json").filter(
    (entry) => typeof entry.value === "string"
  );
}

function normalizeValue(value: unknown): NormalizedValue {
  if (BigNumber.isBigNumber(value)) return value.toString();
  if (typeof value === "string") return /^0x[0-9a-fA-F]{40}$/.test(value) ? ethers.utils.getAddress(value) : value;
  if (typeof value === "number" || typeof value === "boolean" || value === null) return value;
  if (Array.isArray(value)) return value.map((entry) => normalizePrimitive(normalizeValue(entry) as Primitive));
  if (value && typeof value === "object") {
    const result: Record<string, Primitive> = {};
    for (const [key, entry] of Object.entries(value)) {
      const normalized = normalizeValue(entry);
      if (isPrimitive(normalized)) result[key] = normalized;
    }
    return result;
  }
  return String(value);
}

function stringifyValue(value: unknown): string {
  if (BigNumber.isBigNumber(value)) return value.toString();
  return JSON.stringify(value);
}

function isSupportedOutputType(outputType: string): boolean {
  const normalized = outputType.replace(/\[[^\]]*\]$/, "");
  return (
    normalized === "address" ||
    normalized === "bool" ||
    normalized === "string" ||
    normalized === "bytes32" ||
    normalized.startsWith("uint") ||
    normalized.startsWith("int")
  );
}

function primitiveEqual(left: Primitive, right: Primitive): boolean {
  return normalizePrimitive(left) === normalizePrimitive(right);
}

function normalizePrimitive(value: Primitive): Primitive {
  if (typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value)) return ethers.utils.getAddress(value);
  return value;
}

function isPrimitive(value: unknown): value is Primitive {
  return value === null || ["string", "number", "boolean"].includes(typeof value);
}

function asPrimitive(value: unknown): Primitive | undefined {
  return isPrimitive(value) ? normalizePrimitive(value) : undefined;
}

function getObjectPath(input: unknown, parts: string[]): unknown {
  let current: unknown = input;
  for (const part of parts) {
    if (!current || typeof current !== "object" || !(part in (current as Record<string, unknown>))) return undefined;
    current = (current as Record<string, unknown>)[part];
  }
  return current;
}

function resolveHubChainId(chainId: number, constants: Record<string, unknown>): number {
  const mainnet = Number(getObjectPath(constants, ["CHAIN_IDs", "MAINNET"]) || 1);
  const sepolia = Number(getObjectPath(constants, ["CHAIN_IDs", "SEPOLIA"]) || 11155111);
  const testnets = ((getObjectPath(constants, ["TESTNET_CHAIN_IDs"]) as unknown[]) || []).map(Number);
  if (chainId === mainnet || chainId === sepolia) return chainId;
  return testnets.includes(chainId) ? sepolia : mainnet;
}

function findNatspecKey(artifact: ArtifactLike, signature: string): string | null {
  const keys = new Set([
    ...Object.keys(artifact.userdoc?.methods || {}),
    ...Object.keys(artifact.devdoc?.methods || {}),
  ]);
  for (const key of keys) {
    if (key.startsWith(signature.replace("()", "("))) return key;
  }
  return null;
}

function extractJsonArray(response: string): string {
  const fenced = response.match(/```json\s*([\s\S]*?)```/i);
  if (fenced) return fenced[1];
  const start = response.indexOf("[");
  const end = response.lastIndexOf("]");
  if (start === -1 || end === -1 || end < start)
    throw new Error(`Claude response did not contain a JSON array: ${response}`);
  return response.slice(start, end + 1);
}

function mustGetEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable ${name}.`);
  return value;
}

function truncateForTable(input: string, maxLength = 120): string {
  return input.length <= maxLength ? input : `${input.slice(0, maxLength - 3)}...`;
}

function escapePipes(input: string): string {
  return input.replace(/\|/g, "\\|").replace(/\n/g, " ");
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
