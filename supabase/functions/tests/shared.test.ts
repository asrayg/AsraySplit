// Run with: node --test supabase/functions/tests/   (Node 22.6+ strips TypeScript types)
// or:       deno test supabase/functions/tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { toMinorUnits, fractionDigits } from "../_shared/money.ts";
import { normalizeReceipt, InvalidOutput, sniffImageType, MAX_ITEMS } from "../_shared/receipt.ts";
import { buildAPNsPayload, inQuietHours, isDeadToken, apnsJWT } from "../_shared/push.ts";
import { parseFrankfurter } from "../_shared/rates.ts";
import { redact, fromPostgrest } from "../_shared/http.ts";

test("minor units are exact for 0/2/3-digit currencies", () => {
  assert.equal(fractionDigits("JPY"), 0);
  assert.equal(fractionDigits("kwd"), 3);
  assert.equal(toMinorUnits("12.34", "USD"), 1234);
  assert.equal(toMinorUnits(0.1 + 0.2, "USD"), 30);
  assert.equal(toMinorUnits("12,50", "EUR"), 1250);
  assert.equal(toMinorUnits("1,234.56", "USD"), 123456);
  assert.equal(toMinorUnits("1500", "JPY"), 1500);
  assert.equal(toMinorUnits("1.2345", "KWD"), 1235);
  assert.equal(toMinorUnits("-5.00", "USD"), -500);
  assert.equal(toMinorUnits("abc", "USD"), null);
  assert.equal(toMinorUnits("999999999999", "USD"), null);
});

const good = {
  merchant: "Cafe Margo", purchased_at: "2026-10-19T12:00:00Z", currency: "usd",
  items: [{ name: "Latte", quantity: 1, line_total: "5.50", confidence: 0.95 }, { name: "Toast", quantity: 2, line_total: "8.00", confidence: 0.9 },
          { name: "Coupon", quantity: 1, line_total: "-1.00", confidence: 0.8 }],
  subtotal: "12.50", tax: "1.10", service_fee: null, tip: "2.00", discount: null, total: "15.60", confidence: 0.92,
  field_confidence: { merchant: 0.9, date: 0.8, currency: 0.9, subtotal: 0.9, tax: 0.9, tip: 0.6, total: 0.95 },
};

test("normalizes a valid receipt and folds line discounts", () => {
  const result = normalizeReceipt(good, "EUR", "test-model", new Date("2026-10-20T00:00:00Z"));
  assert.equal(result.currency, "USD");
  assert.deepEqual(result.items.map((i) => i.amount_minor), [550, 800]);
  assert.equal(result.discount_minor, 100);
  assert.equal(result.tax_minor, 110);
  assert.equal(result.total_minor, 1560);
  assert.equal(result.reconciled, true);
  assert.equal(result.confidence, 0.92);
});

test("unreconciled output is flagged low confidence, not trusted", () => {
  const result = normalizeReceipt({ ...good, total: "99.00" }, "USD", "m");
  assert.equal(result.reconciled, false);
  assert.ok(result.confidence <= 0.5);
});

test("rejects malformed or out-of-bounds output", () => {
  assert.throws(() => normalizeReceipt(null, "USD", "m"), InvalidOutput);
  assert.throws(() => normalizeReceipt({ ...good, items: "x" }, "USD", "m"), InvalidOutput);
  assert.throws(() => normalizeReceipt({ ...good, tax: "-3.00" }, "USD", "m"), InvalidOutput);
  assert.throws(() => normalizeReceipt({ ...good, items: [{ name: "x", quantity: 1, line_total: "??", confidence: 1 }] }, "USD", "m"), InvalidOutput);
  const many = Array.from({ length: MAX_ITEMS + 1 }, () => ({ name: "a", quantity: 1, line_total: "1.00", confidence: 1 }));
  assert.throws(() => normalizeReceipt({ ...good, items: many }, "USD", "m"), InvalidOutput);
});

test("drops implausible dates and control characters", () => {
  const result = normalizeReceipt({ ...good, purchased_at: "2099-01-01", merchant: "Bad\u0000Name" }, "USD", "m", new Date("2026-10-20T00:00:00Z"));
  assert.equal(result.purchased_at, null);
  assert.equal(result.merchant, "Bad Name");
});

test("sniffs image types by magic bytes", () => {
  assert.equal(sniffImageType(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])), "image/jpeg");
  assert.equal(sniffImageType(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 0])), "image/png");
  assert.equal(sniffImageType(new TextEncoder().encode("\0\0\0\x18ftypheic....")), "image/heic");
  assert.equal(sniffImageType(new TextEncoder().encode("<html>")), null);
});

test("push payloads hide details unless opted in", () => {
  const job = { id: 1, user_id: "u", trip_id: "t", kind: "expense_created", payload: { trip_id: "t", entity_id: "e" } };
  const hidden = buildAPNsPayload(job, { tripName: "Lisbon", description: "Dinner", amountText: "€40", showDetails: false });
  assert.equal((hidden.aps as any).alert.body, "A new expense was added");
  assert.ok(!JSON.stringify(hidden).includes("Dinner"));
  assert.equal(hidden.entity_id, "e");
  const shown = buildAPNsPayload(job, { tripName: "Lisbon", actorName: "Sam", description: "Dinner", amountText: "€40", showDetails: true });
  assert.match((shown.aps as any).alert.body, /Dinner · €40/);
});

test("quiet hours wrap around midnight", () => {
  const quiet = { start: "22:00:00", end: "07:00:00", timezone: "UTC" };
  assert.equal(inQuietHours(new Date("2026-10-20T23:30:00Z"), quiet), true);
  assert.equal(inQuietHours(new Date("2026-10-20T06:59:00Z"), quiet), true);
  assert.equal(inQuietHours(new Date("2026-10-20T12:00:00Z"), quiet), false);
  assert.equal(inQuietHours(new Date(), null), false);
});

test("dead APNs tokens are recognized", () => {
  assert.equal(isDeadToken(410, "Unregistered"), true);
  assert.equal(isDeadToken(400, "BadDeviceToken"), true);
  assert.equal(isDeadToken(429, "TooManyRequests"), false);
});

test("APNs provider tokens are valid ES256 JWTs", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
  const token = await apnsJWT(pem, "KEY123", "TEAM456", 1_800_000_000);
  const [header, claims, signature] = token.split(".");
  const decode = (part: string) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  assert.deepEqual(decode(header), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(decode(claims), { iss: "TEAM456", iat: 1_800_000_000 });
  const sig = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, sig, new TextEncoder().encode(`${header}.${claims}`)), true);
});

test("exchange-rate responses are validated", () => {
  assert.deepEqual(parseFrankfurter({ amount: 1, base: "EUR", date: "2026-10-19", rates: { USD: 1.0825 } }, "USD"), { rate: "1.0825", asOf: "2026-10-19" });
  assert.throws(() => parseFrankfurter({ amount: 1, date: "2026-10-19", rates: { USD: -1 } }, "USD"));
  assert.throws(() => parseFrankfurter({ amount: 1, date: "2026-10-19", rates: {} }, "USD"));
});

test("logs are redacted and RPC errors mapped", () => {
  assert.equal(redact("user a@b.com token eyJa.eyJb.sig"), "user <redacted> token <redacted>");
  assert.equal(fromPostgrest({ code: "PT429", message: "scan_quota_exceeded", hint: "limit" })?.status, 429);
  assert.equal(fromPostgrest({ code: "42501", message: "not_trip_member" })?.status, 403);
  assert.equal(fromPostgrest(null), null);
});
