import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { apnsJWT, buildAPNsPayload, inQuietHours, isDeadToken, type PushJob } from "./push.ts";
import { log } from "./http.ts";
import { renderEmail, sendWithResend, unsubscribeURL, type EmailJob } from "./email.ts";
import { optionalEnv } from "./supabase.ts";

/** Deletes storage objects whose database rows are gone (receipt/trip/account deletion). */
export async function drainStorageCleanup(admin: SupabaseClient, limit = 200): Promise<number> {
  const { data, error } = await admin.rpc("claim_storage_cleanup", { p_limit: limit });
  if (error || !data?.length) return 0;
  const rows = data as { id: number; bucket_id: string; object_path: string }[];
  const byBucket = new Map<string, typeof rows>();
  for (const row of rows) byBucket.set(row.bucket_id, [...(byBucket.get(row.bucket_id) ?? []), row]);
  let removed = 0;
  for (const [bucket, items] of byBucket) {
    const result = await admin.storage.from(bucket).remove(items.map((item) => item.object_path));
    await admin.rpc("finish_storage_cleanup", { p_ids: items.map((item) => item.id), p_error: result.error ? "remove_failed" : null });
    if (!result.error) removed += items.length;
  }
  return removed;
}

let cachedToken: { value: string; issuedAt: number } | null = null;

async function providerToken(): Promise<string | null> {
  const key = optionalEnv("APNS_PRIVATE_KEY"), keyId = optionalEnv("APNS_KEY_ID"), teamId = optionalEnv("APNS_TEAM_ID");
  if (!key || !keyId || !teamId) return null;
  const now = Math.floor(Date.now() / 1000);
  if (!cachedToken || now - cachedToken.issuedAt > 40 * 60) cachedToken = { value: await apnsJWT(key, keyId, teamId, now), issuedAt: now };
  return cachedToken.value;
}

/** Sends due push jobs. Claiming uses SKIP LOCKED, and dedupe keys make replays harmless. */
export async function dispatchPush(admin: SupabaseClient, limit = 100): Promise<{ sent: number; failed: number; skipped: number }> {
  const stats = { sent: 0, failed: 0, skipped: 0 };
  const token = await providerToken();
  const { data, error } = await admin.rpc("claim_push_jobs", { p_limit: limit });
  if (error || !data?.length) return stats;
  for (const job of data as PushJob[]) {
    if (!token) {
      await admin.rpc("finish_push_job", { p_job_id: job.id, p_status: "skipped", p_error: "apns_not_configured" });
      stats.skipped++;
      continue;
    }
    const [{ data: devices }, { data: prefs }, { data: trip }] = await Promise.all([
      admin.from("devices").select("apns_token, environment, bundle_id").eq("user_id", job.user_id),
      admin.from("notification_preferences").select("show_details_on_lock_screen, quiet_hours_start, quiet_hours_end, timezone, push_enabled").eq("user_id", job.user_id).maybeSingle(),
      job.trip_id ? admin.from("trips").select("name").eq("id", job.trip_id).maybeSingle() : Promise.resolve({ data: null }),
    ]);
    const quiet = prefs?.quiet_hours_start && prefs?.quiet_hours_end ? { start: prefs.quiet_hours_start, end: prefs.quiet_hours_end, timezone: prefs.timezone ?? "UTC" } : null;
    if (prefs?.push_enabled === false || !devices?.length || inQuietHours(new Date(), quiet)) {
      await admin.rpc("finish_push_job", { p_job_id: job.id, p_status: "skipped", p_error: null });
      stats.skipped++;
      continue;
    }
    const payload = buildAPNsPayload(job, { tripName: trip?.name, showDetails: prefs?.show_details_on_lock_screen === true });
    let delivered = false, lastError: string | null = null;
    for (const device of devices) {
      const host = device.environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
      const response = await fetch(`${host}/3/device/${device.apns_token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${token}`, "apns-topic": device.bundle_id, "apns-push-type": "alert",
          "apns-collapse-id": `${job.kind}:${job.payload.entity_id ?? job.id}`.slice(0, 64), "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      if (response.ok) { delivered = true; continue; }
      const reason = (await response.json().catch(() => ({}))).reason as string | undefined;
      if (isDeadToken(response.status, reason)) await admin.from("devices").delete().eq("apns_token", device.apns_token);
      lastError = reason ?? `status_${response.status}`;
    }
    await admin.rpc("finish_push_job", { p_job_id: job.id, p_status: delivered ? "sent" : "failed", p_error: delivered ? null : lastError });
    delivered ? stats.sent++ : stats.failed++;
  }
  log("push_dispatch", stats);
  return stats;
}

/** Sends due reminder emails through Resend. Skipped (not failed) when Resend isn't configured. */
export async function dispatchEmail(admin: SupabaseClient, limit = 50): Promise<{ sent: number; failed: number; skipped: number }> {
  const stats = { sent: 0, failed: 0, skipped: 0 };
  const apiKey = optionalEnv("RESEND_API_KEY"), from = optionalEnv("EMAIL_FROM"), secret = optionalEnv("EMAIL_LINK_SECRET");
  const { data, error } = await admin.rpc("claim_email_jobs", { p_limit: limit });
  if (error || !data?.length) return stats;
  const webBase = `https://${optionalEnv("INVITE_HOST") ?? "asraysplit.app"}`;
  const functionsBase = `${optionalEnv("SUPABASE_URL")}/functions/v1`;
  for (const job of data as EmailJob[]) {
    if (!apiKey || !from || !secret) {
      await admin.rpc("finish_email_job", { p_job_id: job.id, p_status: "skipped", p_error: "email_not_configured" });
      stats.skipped++;
      continue;
    }
    const { data: user } = await admin.auth.admin.getUserById(job.user_id);
    const { data: prefs } = await admin.from("notification_preferences").select("email_reminders").eq("user_id", job.user_id).maybeSingle();
    const email = user?.user?.email;
    // Apple "Hide My Email" relay addresses work; users without an email (none today) are skipped.
    if (!email || prefs?.email_reminders === false) {
      await admin.rpc("finish_email_job", { p_job_id: job.id, p_status: "skipped", p_error: email ? "opted_out" : "no_email" });
      stats.skipped++;
      continue;
    }
    const unsubscribe = await unsubscribeURL(`${functionsBase}/email-unsubscribe`, job.user_id, secret);
    const rendered = renderEmail(job, { trip: `${webBase}/trip/${job.trip_id}/balances`, unsubscribe });
    const result = await sendWithResend(apiKey, {
      from, to: email, ...rendered, unsubscribe, idempotencyKey: `email-job-${job.id}`, tags: { kind: job.kind },
    });
    if (result.ok) {
      await admin.rpc("finish_email_job", { p_job_id: job.id, p_status: "sent", p_error: null, p_provider_id: result.id });
      stats.sent++;
    } else {
      await admin.rpc("finish_email_job", { p_job_id: job.id, p_status: result.retryable ? "failed" : "skipped", p_error: result.error });
      result.retryable ? stats.failed++ : stats.skipped++;
    }
  }
  log("email_dispatch", stats);
  return stats;
}
