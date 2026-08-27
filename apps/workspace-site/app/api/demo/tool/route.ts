import { attachDemoCookie, getOrCreateDemoSession } from '../../../../lib/demo-session';
import { executeDemoRead } from '../../../../lib/demo-executor';
import { loadDemoWorkspace, recordDemoRead } from '../../../../lib/demo-store';
import { assertSameOrigin, json, readJsonObject, safeRoute } from '../../../../lib/http';
import { validateToolArguments } from '../../../../lib/input-validation';
import { WORKSPACE_TOOL_MAP, isWorkspaceToolName } from '../../../../lib/tool-registry';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const session = await getOrCreateDemoSession(request);
    const body = await readJsonObject(request);
    const name = typeof body.tool === 'string' ? body.tool : '';
    if (!isWorkspaceToolName(name)) throw new Error('This tool is not available.');
    const tool = WORKSPACE_TOOL_MAP.get(name)!;
    if (!tool.readOnly || name === 'workspace_focus_view') throw new Error('This tool cannot run through the demo read route.');
    const args = validateToolArguments(body.args ?? {}, tool.inputSchema);
    const result = await executeDemoRead(session.workspaceId, name, args);
    await recordDemoRead(session.workspaceId, tool.title);
    return attachDemoCookie(json({ result, workspace: await loadDemoWorkspace(session.workspaceId), expiresAt: session.expiresAt }), session);
  });
}
