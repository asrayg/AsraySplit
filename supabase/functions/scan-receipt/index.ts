// POST { receipt_id } -> normalized receipt extraction.
// 1. Authenticate the user and let `begin_receipt_scan` check membership + quotas (as the user).
// 2. Download the private object with the service role and validate it.
// 3. Call the AI provider with a timeout and one retry on transient errors.
// 4. Validate/normalize the output; persist result + usage metrics (never receipt contents in logs).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { errorResponse, fromPostgrest, HttpError, json, log, readJson, UUID_PATTERN } from "../_shared/http.ts";
import { adminClient, optionalEnv, requireUser, userClient } from "../_shared/supabase.ts";
import { EXTRACTION_PROMPT, InvalidOutput, normalizeReceipt, RECEIPT_SCHEMA, sniffImageType } from "../_shared/receipt.ts";

const MODEL = optionalEnv("RECEIPT_MODEL") ?? "gpt-4.1-mini";
const TIMEOUT_MS = 45_000;
const MAX_BYTES = 10 * 1024 * 1024;

async function callModel(imageBase64: string, mimeType: string): Promise<{ output: unknown; inputTokens?: number; outputTokens?: number }> {
  const apiKey = optionalEnv("OPENAI_API_KEY");
  if (!apiKey) throw new HttpError(503, "ai_not_configured", "Receipt AI is not configured.");
  let lastError: unknown;
  for (let attempt = 1; attempt <= 2; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
      const response = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        signal: controller.signal,
        headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model: MODEL,
          store: false,
          input: [{ role: "user", content: [
            { type: "input_text", text: EXTRACTION_PROMPT },
            { type: "input_image", image_url: `data:${mimeType};base64,${imageBase64}`, detail: "high" },
          ] }],
          text: { format: { type: "json_schema", name: "receipt", strict: true, schema: RECEIPT_SCHEMA } },
        }),
      });
      if (response.status === 429 || response.status >= 500) {
        lastError = new HttpError(503, "ai_unavailable", "The receipt reader is busy. Try again or enter items manually.");
        continue;
      }
      if (!response.ok) throw new HttpError(502, "ai_rejected", "The receipt reader couldn’t process this image.");
      const result = await response.json();
      const text = result.output?.flatMap((part: { content?: unknown[] }) => part.content ?? [])
        .find((content: { type?: string }) => content.type === "output_text")?.text;
      if (!text) throw new InvalidOutput("empty output");
      return { output: JSON.parse(text), inputTokens: result.usage?.input_tokens, outputTokens: result.usage?.output_tokens };
    } catch (error) {
      if (error instanceof HttpError || error instanceof InvalidOutput || error instanceof SyntaxError) throw error;
      lastError = (error as Error).name === "AbortError" ? new HttpError(504, "ai_timeout", "Reading the receipt took too long.") : error;
    } finally {
      clearTimeout(timer);
    }
  }
  throw lastError instanceof HttpError ? lastError : new HttpError(503, "ai_unavailable", "The receipt reader is unavailable.");
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ code: "method_not_allowed", message: "Use POST." }, 405);
  const started = Date.now();
  let usageId: string | undefined;
  let receiptId: string | undefined;
  const admin = adminClient();
  try {
    const client = userClient(request);
    const user = await requireUser(client);
    const body = await readJson<{ receipt_id?: string }>(request);
    receiptId = body.receipt_id;
    if (!receiptId || !UUID_PATTERN.test(receiptId)) throw new HttpError(400, "invalid_receipt", "A receipt id is required.");

    const begin = await client.rpc("begin_receipt_scan", { p_receipt_id: receiptId });
    const beginError = fromPostgrest(begin.error);
    if (beginError) throw beginError;
    const job = begin.data as { cached: boolean; result?: unknown; usage_id?: string; object_path?: string; mime_type?: string; base_currency?: string };
    if (job.cached) return json(job.result);
    usageId = job.usage_id;

    const download = await admin.storage.from("receipts").download(job.object_path!);
    if (download.error || !download.data) throw new HttpError(404, "receipt_missing", "The receipt image is no longer available.");
    const bytes = new Uint8Array(await download.data.arrayBuffer());
    if (bytes.length === 0 || bytes.length > MAX_BYTES) throw new HttpError(413, "receipt_too_large", "The receipt image is too large.");
    const sniffed = sniffImageType(bytes);
    if (!sniffed || sniffed === "application/pdf" || sniffed !== job.mime_type) {
      throw new HttpError(415, "unsupported_image", "Receipts must be JPEG, PNG or HEIC images.");
    }

    const { output, inputTokens, outputTokens } = await callModel(toBase64(bytes), sniffed);
    const normalized = normalizeReceipt(output, job.base_currency ?? "USD", MODEL);
    const latency = Date.now() - started;
    await admin.rpc("complete_receipt_scan", {
      p_receipt_id: receiptId, p_usage_id: usageId, p_outcome: "succeeded", p_result: normalized, p_model: MODEL,
      p_latency_ms: latency, p_input_tokens: inputTokens ?? null, p_output_tokens: outputTokens ?? null, p_error_code: null,
    });
    log("receipt_scan", { outcome: "succeeded", latency_ms: latency, items: normalized.items.length, reconciled: normalized.reconciled, user: user.id });
    return json(normalized);
  } catch (error) {
    const code = error instanceof InvalidOutput || error instanceof SyntaxError ? "invalid_output" : error instanceof HttpError ? error.code : "internal_error";
    if (usageId && receiptId) {
      await admin.rpc("complete_receipt_scan", {
        p_receipt_id: receiptId, p_usage_id: usageId, p_outcome: code === "ai_timeout" ? "timeout" : code === "invalid_output" ? "invalid_output" : "failed",
        p_result: null, p_model: MODEL, p_latency_ms: Date.now() - started, p_input_tokens: null, p_output_tokens: null, p_error_code: code,
      });
    }
    log("receipt_scan", { outcome: "failed", code, latency_ms: Date.now() - started });
    if (code === "invalid_output") return json({ code, message: "The receipt couldn’t be read reliably. Review it manually." }, 422);
    return errorResponse(error);
  }
});
