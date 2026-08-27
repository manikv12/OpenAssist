declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    FILES: R2Bucket;
    WORKSPACE_MCP_URL?: string;
    WORKSPACE_OAUTH_ISSUER?: string;
    WORKSPACE_OAUTH_CLIENT_ID?: string;
    WORKSPACE_OAUTH_CLIENT_SECRET?: string;
    SITE_PUBLIC_ORIGIN?: string;
    OWNER_BOOTSTRAP_CODE?: string;
    TOKEN_ENCRYPTION_KEY?: string;
    ACTION_SIGNING_KEY?: string;
    VOICE_GATEWAY_URL?: string;
    VOICE_GATEWAY_SHARED_SECRET?: string;
  }
}
