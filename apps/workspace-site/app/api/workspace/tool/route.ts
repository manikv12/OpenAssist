import { assertSameOrigin, readJsonObject, safeRoute } from '../../../../lib/http';
import { validateToolArguments } from '../../../../lib/input-validation';
import { executeLiveWorkspaceTool, workspaceAccessToken } from '../../../../lib/mcp-client';
import { requireOwner } from '../../../../lib/server-auth';
import { WORKSPACE_TOOL_MAP, isWorkspaceToolName } from '../../../../lib/tool-registry';

export async function POST(request: Request): Promise<Response> {
  return safeRoute(async () => {
    assertSameOrigin(request);
    const user = await requireOwner();
    const body = await readJsonObject(request);
    const name = typeof body.tool === 'string' ? body.tool : '';
    if (!isWorkspaceToolName(name)) throw new Error('This tool is not available.');
    const tool = WORKSPACE_TOOL_MAP.get(name)!;
    if (tool.demoOnly || (!tool.readOnly && tool.approval !== 'policy') || name === 'workspace_focus_view') throw new Error('This tool cannot run through the policy route.');
    const args = validateToolArguments(body.args ?? {}, tool.inputSchema);
    return executeLiveWorkspaceTool(await workspaceAccessToken(user.userId), name, args);
  });
}
