type WebMCPToolAnnotations = {
  readOnlyHint?: boolean;
  untrustedContentHint?: boolean;
};

type WebMCPTool = {
  name: string;
  title?: string;
  description: string;
  inputSchema?: Record<string, unknown>;
  execute: (
    input: Record<string, unknown>,
    options: { signal: AbortSignal },
  ) => Promise<unknown>;
  annotations?: WebMCPToolAnnotations;
};

interface Document {
  readonly modelContext?: {
    registerTool: (
      tool: WebMCPTool,
      options?: { signal?: AbortSignal; exposedTo?: string[] },
    ) => Promise<void>;
  };
}
