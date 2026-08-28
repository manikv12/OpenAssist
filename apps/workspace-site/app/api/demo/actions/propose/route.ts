import { attachDemoCookie, getOrCreateDemoSession } from '../../../../../lib/demo-session';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../../lib/http';
import { validateToolArguments } from '../../../../../lib/input-validation';
import { randomBase64Url, sha256, signActionPreview } from '../../../../../lib/security';
import { requireSignedInUser, requiredSecret } from '../../../../../lib/server-auth';
import { WORKSPACE_TOOL_MAP, isWorkspaceToolName } from '../../../../../lib/tool-registry';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    await requireSignedInUser();
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request);
    const name = typeof body.tool === 'string' ? body.tool : '';
    if (!isWorkspaceToolName(name)) throw new Error('This tool is not available.');
    const tool = WORKSPACE_TOOL_MAP.get(name)!;
    if (tool.readOnly) throw new Error('Read-only tools do not need approval.');
    const args = validateToolArguments(body.args ?? {}, tool.inputSchema);
    const issuedAt = Date.now();
    const payload = {
      version: 1 as const,
      previewId: randomBase64Url(20),
      userId: `demo:${session.workspaceId}`,
      tool: name,
      argsHash: await sha256(args),
      nonce: randomBase64Url(24),
      issuedAt,
      expiresAt: issuedAt + 120_000,
      destructive: Boolean(tool.destructive),
    };
    return attachDemoCookie(json({
      id: payload.previewId,
      token: await signActionPreview(payload, requiredSecret('ACTION_SIGNING_KEY')),
      expiresAt: payload.expiresAt,
    }), session);
  });
}
