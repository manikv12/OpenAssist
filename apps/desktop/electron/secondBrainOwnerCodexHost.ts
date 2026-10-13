import type { CodexPluginMCPBroker } from "./codexPluginMcpBroker.js";
import {
  SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
  SecondBrainAutonomousRunner,
  type SecondBrainAutonomousRunnerOptions,
} from "./secondBrainAutonomousRunnerCore.js";
import {
  IsolatedSecondBrainCodexTransport,
  SecondBrainCodexExecutor,
  type SecondBrainCodexTransportPort,
} from "./secondBrainCodexExecutor.js";
import { SecondBrainWorkspaceBrokerClient } from "./secondBrainWorkspaceBrokerClient.js";

export type SecondBrainOwnerCodexHostOptions = {
  workspaceBroker?: Pick<CodexPluginMCPBroker, "findTools" | "callTool">;
  workspaceToolCaller?: { callNamedTool(name: string, args: Record<string, unknown>): Promise<unknown> };
  transport?: SecondBrainCodexTransportPort;
  codexExecutable?: string;
  model?: string;
  reasoningEffort?: "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
  leaseSeconds?: number;
};

/**
 * Safe composition root for one trusted local owner orchestrator.
 *
 * The host deliberately receives the already-authenticated Workspace broker,
 * while Codex runs in a separate tool-free ephemeral app-server process. This
 * prevents the model from receiving the broker or any Google/computer tool.
 */
export class SecondBrainOwnerCodexHost {
  readonly runner: SecondBrainAutonomousRunner;
  private readonly transport: SecondBrainCodexTransportPort;
  private readonly ownsTransport: boolean;

  constructor(options: SecondBrainOwnerCodexHostOptions) {
    const workspaceAccess = options.workspaceToolCaller ?? options.workspaceBroker;
    if (!workspaceAccess) throw new Error("Second Brain owner host requires narrow Workspace access.");
    this.ownsTransport = !options.transport;
    this.transport = options.transport ?? new IsolatedSecondBrainCodexTransport({ executable: options.codexExecutable });
    const workspace = new SecondBrainWorkspaceBrokerClient(workspaceAccess);
    const executor = new SecondBrainCodexExecutor({
      transport: this.transport,
      model: options.model,
      reasoningEffort: options.reasoningEffort,
    });
    const runnerOptions: SecondBrainAutonomousRunnerOptions = {
      workspace,
      executor,
      ownerSession: {
        isOwner: true,
        trustedLocalOrchestrator: true,
        orchestratorId: SECOND_BRAIN_OWNER_ORCHESTRATOR_ID,
      },
      leaseSeconds: options.leaseSeconds,
    };
    this.runner = new SecondBrainAutonomousRunner(runnerOptions);
  }

  runOnce() {
    return this.runner.runOnce();
  }

  runUntilStopped(input: Parameters<SecondBrainAutonomousRunner["runUntilStopped"]>[0] = {}) {
    return this.runner.runUntilStopped(input);
  }

  async stop() {
    this.runner.stop();
    if (this.ownsTransport) await this.transport.stop?.();
  }
}
