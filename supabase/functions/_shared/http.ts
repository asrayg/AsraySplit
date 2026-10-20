// HTTP helpers shared by every Edge Function. Error bodies follow the app's contract:
// { "code": "<machine_code>", "message": "<human text>" } with a matching HTTP status.

export class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) return json({ code: error.code, message: error.message }, error.status);
  return json({ code: "internal_error", message: "Something went wrong. Please try again." }, 500);
}

/** Maps PostgREST errors raised by our RPCs (see the SQL error contract) to HTTP errors. */
export function fromPostgrest(error: { code?: string; message?: string; hint?: string } | null): HttpError | null {
  if (!error) return null;
  const code = error.message ?? "rpc_error";
  const hint = error.hint ?? "Request failed.";
  switch (error.code) {
    case "42501": return new HttpError(code === "not_authenticated" ? 401 : 403, code, hint);
    case "PT404": return new HttpError(404, code, hint);
    case "PT409": return new HttpError(409, code, hint);
    case "PT429": return new HttpError(429, code, hint);
    case "22023": return new HttpError(400, code, hint);
    default: return new HttpError(500, "rpc_error", "Request failed.");
  }
}

const SECRET_PATTERNS: RegExp[] = [
  /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, // JWTs
  /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, // emails
  /\b[0-9a-f]{64,}\b/g, // device tokens / hashes
  /sk-[A-Za-z0-9_-]{10,}/g, // provider keys
];

/** Removes secrets and personal data from text before it reaches logs. */
export function redact(text: string): string {
  return SECRET_PATTERNS.reduce((value, pattern) => value.replace(pattern, "<redacted>"), text);
}

/** Structured log line. Never pass receipt contents, amounts or merchants here. */
export function log(event: string, fields: Record<string, string | number | boolean | null | undefined> = {}): void {
  const safe: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(fields)) safe[key] = typeof value === "string" ? redact(value) : value;
  console.log(JSON.stringify({ event, ...safe, at: new Date().toISOString() }));
}

export async function readJson<T>(request: Request, maxBytes = 64 * 1024): Promise<T> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > maxBytes) throw new HttpError(413, "payload_too_large", "Request body is too large.");
  const text = await request.text();
  if (text.length > maxBytes) throw new HttpError(413, "payload_too_large", "Request body is too large.");
  try {
    return JSON.parse(text || "{}") as T;
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be JSON.");
  }
}

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
