import { test } from "node:test";
import assert from "node:assert/strict";
import { formatMoney, renderEmail, unsubscribeURL, verifyUnsubscribe, type EmailJob } from "../_shared/email.ts";

const job: EmailJob = {
  id: 7, user_id: "u1", trip_id: "t1", kind: "payment_request",
  data: { trip_name: "Porto <script>", trip_emoji: "🍷", currency: "EUR", amount_minor: 4000, pay_to: [{ name: "Maya", amount_minor: 4000 }], requested_by: "Maya" },
};

test("formats exact minor units per currency", () => {
  assert.equal(formatMoney(4000, "EUR", "en-US"), "€40.00");
  assert.equal(formatMoney(1500, "JPY", "en-US"), "¥1,500");
  assert.equal(formatMoney(1005, "KWD", "en-US").includes("1.005"), true);
});

test("renders reminder with amounts, links and escaped content", () => {
  const email = renderEmail(job, { trip: "https://asraysplit.app/trip/t1/balances", unsubscribe: "https://x/unsub?u=u1&s=abc" });
  assert.match(email.subject, /Maya sent a reminder for Porto/);
  assert.match(email.text, /Maya: €40\.00/);
  assert.match(email.text, /Stop reminder emails: https:\/\/x\/unsub/);
  assert.ok(!email.html.includes("<script>"), "user-controlled names are escaped");
  assert.match(email.html, /&lt;script&gt;/);
  const settle = renderEmail({ ...job, kind: "settle_up_reminder" }, { trip: "t", unsubscribe: "u" });
  assert.match(settle.subject, /Time to settle up/);
});

test("unsubscribe links are signed per user", async () => {
  const url = new URL(await unsubscribeURL("https://fn/email-unsubscribe", "user-1", "secret"));
  const signature = url.searchParams.get("s")!;
  assert.equal(await verifyUnsubscribe("user-1", signature, "secret"), true);
  assert.equal(await verifyUnsubscribe("user-2", signature, "secret"), false);
  assert.equal(await verifyUnsubscribe("user-1", signature, "other-secret"), false);
  assert.equal(await verifyUnsubscribe("user-1", "short", "secret"), false);
});
