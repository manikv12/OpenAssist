import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../lib/demo-session';
import { executeDemoWrite, loadDemoWorkspace } from '../../../../../lib/demo-store';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../../lib/http';
import { validateToolArguments } from '../../../../../lib/input-validation';
import { sha256, verifyActionPreview } from '../../../../../lib/security';
import { requireDemoAccess, requiredSecret } from '../../../../../lib/server-auth';
import { claimIdempotency } from '../../../../../lib/site-db';
import { WORKSPACE_TOOL_MAP, isWorkspaceToolName } from '../../../../../lib/tool-registry';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireDemoAccess(request);
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request);
    const name = typeof body.tool === 'string' ? body.tool : '';
    if (!isWorkspaceToolName(name)) throw new Error('This tool is not available.');
    const tool = WORKSPACE_TOOL_MAP.get(name)!;
    if (tool.readOnly) throw new Error('This tool does not use the approval route.');
    const token = typeof body.token === 'string' ? body.token : '';
    const previewId = typeof body.previewId === 'string' ? body.previewId : '';
    const args = validateToolArguments(body.args ?? {}, tool.inputSchema);
    const payload = await verifyActionPreview(token, requiredSecret('ACTION_SIGNING_KEY'));
    const userId = `demo:${session.workspaceId}`;
    if (
      payload.userId !== userId ||
      payload.previewId !== previewId ||
      payload.tool !== name ||
      payload.expiresAt < Date.now() ||
      payload.argsHash !== await sha256(args)
    ) {
      throw new Error('Approval preview is invalid or expired.');
    }
    if (body.confirmationMethod !== 'tap' && body.confirmationMethod !== 'voice') {
      throw new Error('Approval must come from the visible screen or active voice session.');
    }
    if (payload.destructive && body.confirmationMethod !== 'tap') {
      throw new Error('Approval preview requires an on-screen tap.');
    }
    const receiptHash = await sha256({ previewId, userId, tool: name, argsHash: payload.argsHash, nonce: payload.nonce });
    if (!await claimIdempotency(receiptHash, userId, name)) {
      return attachDemoCookie(json({
        result: { status: 'already_executed', verified: true, mode: 'synthetic_demo' },
        workspace: await loadDemoWorkspace(session.workspaceId),
        expiresAt: session.expiresAt,
      }), session);
    }
    const actor = body.confirmationMethod === 'voice' ? 'Voice + You' : 'You';
    const result = await executeDemoWrite(session.workspaceId, name, args, actor, tool.title);
    return attachDemoCookie(json({ result, workspace: await loadDemoWorkspace(session.workspaceId), expiresAt: session.expiresAt }), session);
  });
}
