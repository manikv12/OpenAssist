import { assertSameOrigin, readJsonObject, safeRoute } from '../../../../lib/http';
import { validateToolArguments } from '../../../../lib/input-validation';
import { executeLiveWorkspaceTool, readBackLiveWrite, workspaceAccessToken } from '../../../../lib/mcp-client';
import { sha256, verifyActionPreview } from '../../../../lib/security';
import { requireOwner, requiredSecret } from '../../../../lib/server-auth';
import { claimIdempotency } from '../../../../lib/site-db';
import { WORKSPACE_TOOL_MAP, isWorkspaceToolName } from '../../../../lib/tool-registry';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const user = await requireOwner();
    const body = await readJsonObject(request);
    const name = typeof body.tool === 'string' ? body.tool : '';
    if (!isWorkspaceToolName(name)) throw new Error('This tool is not available.');
    const tool = WORKSPACE_TOOL_MAP.get(name)!;
    if (tool.readOnly) throw new Error('This tool does not use the approval route.');
    const token = typeof body.token === 'string' ? body.token : '';
    const previewId = typeof body.previewId === 'string' ? body.previewId : '';
    const args = validateToolArguments(body.args ?? {}, tool.inputSchema);
    const payload = await verifyActionPreview(token, requiredSecret('ACTION_SIGNING_KEY'));
    if (payload.userId !== user.userId || payload.previewId !== previewId || payload.tool !== name || payload.expiresAt < Date.now() || payload.argsHash !== await sha256(args)) {
      throw new Error('Approval preview is invalid or expired.');
    }
    if (body.confirmationMethod !== 'tap' && body.confirmationMethod !== 'voice') {
      throw new Error('Approval must come from the visible screen or the active owner voice session.');
    }
    if (payload.destructive && body.confirmationMethod !== 'tap') {
      throw new Error('Approval preview requires an on-screen tap.');
    }
    const receiptHash = await sha256({ previewId, userId: user.userId, tool: name, argsHash: payload.argsHash, nonce: payload.nonce });
    if (!await claimIdempotency(receiptHash, user.userId, name)) {
      return { status: 'already_executed', verified: true };
    }
    const accessToken = await workspaceAccessToken(user.userId);
    // An approved write is attempted exactly once. Failures are returned to the
    // user and never retried silently.
    const result = await executeLiveWorkspaceTool(accessToken, name, args);
    return { status: 'completed', ...(await readBackLiveWrite(accessToken, name, args, result)) };
  });
}
