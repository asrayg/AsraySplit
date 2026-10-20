// Reminder emails rendered from email_jobs.data and sent through Resend.
// Pure helpers (rendering, signing) are unit-tested; `sendWithResend` does the network call.

import { fractionDigits } from "./money.ts";

export interface EmailJob {
  id: number;
  user_id: string;
  trip_id: string | null;
  kind: "settle_up_reminder" | "payment_request";
  data: {
    trip_id?: string; trip_name?: string; trip_emoji?: string; currency?: string; amount_minor?: number;
    pay_to?: { name: string; amount_minor: number }[]; requested_by?: string;
  };
}

export interface RenderedEmail { subject: string; html: string; text: string }

export function formatMoney(minor: number, currency: string, locale = "en-US"): string {
  const digits = fractionDigits(currency);
  return new Intl.NumberFormat(locale, { style: "currency", currency, minimumFractionDigits: digits, maximumFractionDigits: digits })
    .format(minor / 10 ** digits);
}

const escapeHTML = (value: string) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

export function renderEmail(job: EmailJob, links: { trip: string; unsubscribe: string }): RenderedEmail {
  const currency = job.data.currency ?? "USD";
  const trip = `${job.data.trip_emoji ?? ""} ${job.data.trip_name ?? "your trip"}`.trim();
  const total = formatMoney(job.data.amount_minor ?? 0, currency);
  const payTo = (job.data.pay_to ?? []).map((p) => ({ name: p.name, amount: formatMoney(p.amount_minor, currency) }));
  const subject = job.kind === "payment_request"
    ? `${job.data.requested_by ?? "A trip member"} sent a reminder for ${job.data.trip_name ?? "your trip"}`
    : `Time to settle up for ${job.data.trip_name ?? "your trip"}`;
  const intro = job.kind === "payment_request"
    ? `${job.data.requested_by ?? "A trip member"} asked for a reminder about ${trip}. You owe ${total}:`
    : `${trip} has ended. You still owe ${total}:`;
  const footer = "Asray Split doesn’t move money. Pay by cash, bank transfer, Venmo or PayPal, then record the payment in the app.";

  const text = [
    intro,
    ...payTo.map((p) => `• ${p.name}: ${p.amount}`),
    "",
    `Open the trip: ${links.trip}`,
    "",
    footer,
    `Stop reminder emails: ${links.unsubscribe}`,
  ].join("\n");

  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#f4f7f6;font-family:-apple-system,system-ui,sans-serif;color:#0b1a14">
<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;padding:24px">
<p style="font-size:17px;line-height:1.5;margin:0 0 12px">${escapeHTML(intro)}</p>
<ul style="font-size:17px;line-height:1.6;padding-left:20px;margin:0 0 20px">${payTo.map((p) => `<li><strong>${escapeHTML(p.name)}</strong>: ${escapeHTML(p.amount)}</li>`).join("")}</ul>
<a href="${escapeHTML(links.trip)}" style="display:inline-block;background:#0b7f57;color:#fff;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:12px">Open trip</a>
<p style="font-size:13px;color:#4b5b55;line-height:1.5;margin:24px 0 0">${escapeHTML(footer)}</p>
<p style="font-size:13px;color:#4b5b55;margin:8px 0 0"><a href="${escapeHTML(links.unsubscribe)}" style="color:#4b5b55">Stop reminder emails</a></p>
</div></body></html>`;
  return { subject, html, text };
}

async function hmac(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return Array.from(signature, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Signed one-click unsubscribe link (no login needed, can't be forged for other users). */
export async function unsubscribeURL(base: string, userId: string, secret: string): Promise<string> {
  return `${base}?u=${encodeURIComponent(userId)}&s=${await hmac(secret, `unsubscribe:${userId}`)}`;
}

export async function verifyUnsubscribe(userId: string, signature: string, secret: string): Promise<boolean> {
  const expected = await hmac(secret, `unsubscribe:${userId}`);
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

/** Sends one email. The idempotency key makes a retried job a no-op at Resend for 24 hours. */
export async function sendWithResend(apiKey: string, message: {
  from: string; to: string; subject: string; html: string; text: string; unsubscribe: string; idempotencyKey: string; tags: Record<string, string>;
}): Promise<{ ok: true; id: string } | { ok: false; status: number; retryable: boolean; error: string }> {
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json", "Idempotency-Key": message.idempotencyKey },
    body: JSON.stringify({
      from: message.from,
      to: [message.to],
      subject: message.subject,
      html: message.html,
      text: message.text,
      headers: { "List-Unsubscribe": `<${message.unsubscribe}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" },
      tags: Object.entries(message.tags).map(([name, value]) => ({ name, value })),
    }),
  });
  if (response.ok) return { ok: true, id: (await response.json()).id ?? "" };
  const body = await response.json().catch(() => ({})) as { name?: string; message?: string };
  return { ok: false, status: response.status, retryable: response.status === 429 || response.status >= 500, error: body.name ?? `status_${response.status}` };
}
