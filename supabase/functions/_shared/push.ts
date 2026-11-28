// APNs payloads and provider-token signing. Payloads are privacy-safe by default: no amounts or
// merchants unless the user enabled lock-screen details.

export interface PushJob {
  id: number;
  user_id: string;
  trip_id: string | null;
  kind: string;
  payload: { trip_id?: string; entity_id?: string | null; kind?: string; activity_id?: number; title?: string; body?: string };
}

export interface PushContext {
  tripName?: string;
  actorName?: string;
  description?: string;
  amountText?: string;
  showDetails: boolean;
  quietHours?: { start: string; end: string; timezone: string } | null;
}

const GENERIC: Record<string, string> = {
  expense_created: "A new expense was added",
  expense_updated: "An expense was edited",
  expense_deleted: "An expense was deleted",
  expense_restored: "An expense was restored",
  settlement_recorded: "A payment was recorded",
  settlement_deleted: "A payment was removed",
  member_joined: "Someone joined the trip",
  member_left: "Someone left the trip",
  member_removed: "A member was removed",
  receipt_scanned: "Your receipt is ready to review",
  receipt_scan_failed: "We couldn’t read your receipt",
};

export function buildAPNsPayload(job: PushJob, context: PushContext): Record<string, unknown> {
  const generic = GENERIC[job.kind] ?? "Your trip was updated";
  // Crew build: the database writes readable text (who/what/how much, chat text) into the job payload.
  let body = job.payload.body ?? generic;
  if (context.showDetails && context.description) {
    body = `${context.actorName ?? "Someone"}: ${context.description}${context.amountText ? ` · ${context.amountText}` : ""}`;
  }
  return {
    aps: {
      alert: { title: job.payload.title ?? context.tripName ?? "AsraySplit", body },
      sound: "default",
      "thread-id": job.trip_id ?? "general",
      "mutable-content": 0,
    },
    trip_id: job.payload.trip_id ?? job.trip_id,
    entity_id: job.payload.entity_id ?? null,
    kind: job.kind,
  };
}

/** True when `now` falls inside the user's quiet hours (which may wrap past midnight). */
export function inQuietHours(now: Date, quiet: { start: string; end: string; timezone: string } | null | undefined): boolean {
  if (!quiet) return false;
  const parts = new Intl.DateTimeFormat("en-GB", { timeZone: quiet.timezone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(now);
  const minutes = (text: string) => { const [h, m] = text.split(":").map(Number); return h * 60 + m; };
  const current = minutes(parts), start = minutes(quiet.start.slice(0, 5)), end = minutes(quiet.end.slice(0, 5));
  return start <= end ? current >= start && current < end : current >= start || current < end;
}

function base64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Signs an APNs provider token (ES256) from a .p8 key. Tokens are valid for up to an hour. */
export async function apnsJWT(keyPEM: string, keyId: string, teamId: string, issuedAt = Math.floor(Date.now() / 1000)): Promise<string> {
  const der = Uint8Array.from(atob(keyPEM.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: issuedAt }));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)));
  return `${header}.${claims}.${base64url(signature)}`;
}

/** APNs responses that mean the token is permanently invalid and the device row should be deleted. */
export function isDeadToken(status: number, reason: string | undefined): boolean {
  return status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
}
