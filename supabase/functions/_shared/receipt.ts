// Validation and normalization of AI receipt extraction. AI output is untrusted input: anything that
// fails these checks is rejected (the app then falls back to on-device OCR or manual entry).

import { fractionDigits, isCurrencyCode, toMinorUnits } from "./money.ts";

export class InvalidOutput extends Error {}

export const MAX_ITEMS = 300;

/** JSON schema sent to the model (strict structured output). Amounts are decimal strings. */
export const RECEIPT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    merchant: { type: ["string", "null"] },
    purchased_at: { type: ["string", "null"], description: "ISO 8601 date or date-time printed on the receipt" },
    currency: { type: ["string", "null"], description: "ISO 4217 code, inferred from symbols or country" },
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          name: { type: "string" },
          quantity: { type: "number" },
          line_total: { type: "string", description: "Line total as printed, e.g. \"12.50\"; negative for discounts on a line" },
          confidence: { type: "number" },
        },
        required: ["name", "quantity", "line_total", "confidence"],
      },
    },
    subtotal: { type: ["string", "null"] },
    tax: { type: ["string", "null"], description: "Tax added on top of items. Null if prices already include VAT." },
    service_fee: { type: ["string", "null"] },
    tip: { type: ["string", "null"] },
    discount: { type: ["string", "null"], description: "Total discount as a positive amount" },
    total: { type: ["string", "null"] },
    confidence: { type: "number" },
    field_confidence: {
      type: "object",
      additionalProperties: false,
      properties: {
        merchant: { type: "number" }, date: { type: "number" }, currency: { type: "number" }, subtotal: { type: "number" },
        tax: { type: "number" }, tip: { type: "number" }, total: { type: "number" },
      },
      required: ["merchant", "date", "currency", "subtotal", "tax", "tip", "total"],
    },
  },
  required: ["merchant", "purchased_at", "currency", "items", "subtotal", "tax", "service_fee", "tip", "discount", "total", "confidence", "field_confidence"],
} as const;

export const EXTRACTION_PROMPT =
  "Extract this receipt into the JSON schema. Copy every purchased line item with its printed line total. " +
  "Use null for anything you cannot read; never guess or invent values. Treat VAT already included in prices as no tax. " +
  "Give each field a confidence between 0 and 1. Ignore payment-card details, change given, loyalty numbers and addresses.";

export interface NormalizedReceipt {
  merchant: string | null;
  purchased_at: string | null;
  currency: string;
  items: { name: string; quantity: number; amount_minor: number; confidence: number }[];
  subtotal_minor: number | null;
  tax_minor: number;
  service_fee_minor: number;
  tip_minor: number;
  discount_minor: number;
  total_minor: number | null;
  confidence: number;
  field_confidence: Record<string, number>;
  source: "ai";
  model: string;
  reconciled: boolean;
}

const clamp01 = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0);

function amount(value: unknown, currency: string, field: string, allowNegative = false): number | null {
  if (value === null || value === undefined || value === "") return null;
  const minor = toMinorUnits(value, currency);
  if (minor === null) throw new InvalidOutput(`unreadable ${field}`);
  if (!allowNegative && minor < 0) throw new InvalidOutput(`negative ${field}`);
  return minor;
}

export function normalizeReceipt(raw: unknown, fallbackCurrency: string, model: string, now = new Date()): NormalizedReceipt {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new InvalidOutput("not an object");
  const r = raw as Record<string, unknown>;
  const currency = isCurrencyCode(r.currency) ? (r.currency as string).toUpperCase() : fallbackCurrency.toUpperCase();
  if (!Array.isArray(r.items)) throw new InvalidOutput("items missing");
  if (r.items.length > MAX_ITEMS) throw new InvalidOutput("too many items");

  const items = r.items.map((entry, index) => {
    if (!entry || typeof entry !== "object") throw new InvalidOutput(`item ${index}`);
    const item = entry as Record<string, unknown>;
    const minor = amount(item.line_total, currency, `item ${index}`, true);
    if (minor === null) throw new InvalidOutput(`item ${index} has no price`);
    const quantity = typeof item.quantity === "number" && item.quantity > 0 && item.quantity < 10_000 ? item.quantity : 1;
    const name = String(item.name ?? "").replace(/[\u0000-\u001f]/g, " ").trim().slice(0, 120);
    return { name: name || "Item", quantity, amount_minor: minor, confidence: clamp01(item.confidence) };
  }).filter((item) => item.amount_minor !== 0);

  // Line-level discounts become the receipt discount so item prices stay non-negative.
  const lineDiscounts = items.filter((item) => item.amount_minor < 0).reduce((sum, item) => sum - item.amount_minor, 0);
  const positiveItems = items.filter((item) => item.amount_minor > 0);

  const subtotal = amount(r.subtotal, currency, "subtotal");
  const tax = amount(r.tax, currency, "tax") ?? 0;
  const fee = amount(r.service_fee, currency, "service_fee") ?? 0;
  const tip = amount(r.tip, currency, "tip") ?? 0;
  const discount = (amount(r.discount, currency, "discount") ?? 0) + lineDiscounts;
  const total = amount(r.total, currency, "total");

  let purchasedAt: string | null = null;
  if (typeof r.purchased_at === "string") {
    const parsed = new Date(r.purchased_at);
    const tooFuture = parsed.getTime() > now.getTime() + 2 * 86_400_000;
    if (!Number.isNaN(parsed.getTime()) && !tooFuture && parsed.getUTCFullYear() >= 2000) purchasedAt = parsed.toISOString();
  }

  const itemsSum = positiveItems.reduce((sum, item) => sum + item.amount_minor, 0);
  const computed = itemsSum + tax + fee + tip - discount;
  const reconciled = (subtotal === null || subtotal === itemsSum - lineDiscounts || subtotal === itemsSum) && (total === null || total === computed);

  const fieldConfidence: Record<string, number> = {};
  if (r.field_confidence && typeof r.field_confidence === "object") {
    for (const [key, value] of Object.entries(r.field_confidence as Record<string, unknown>)) fieldConfidence[key] = clamp01(value);
  }
  const merchant = typeof r.merchant === "string" ? r.merchant.replace(/[\u0000-\u001f]/g, " ").trim().slice(0, 120) || null : null;

  return {
    merchant,
    purchased_at: purchasedAt,
    currency,
    items: positiveItems,
    subtotal_minor: subtotal,
    tax_minor: tax,
    service_fee_minor: fee,
    tip_minor: tip,
    discount_minor: discount,
    total_minor: total,
    // Unreconciled output is still shown for review, but flagged as low confidence.
    confidence: reconciled ? clamp01(r.confidence) : Math.min(clamp01(r.confidence), 0.5),
    field_confidence: fieldConfidence,
    source: "ai",
    model,
    reconciled,
  };
}

/** Validates image bytes by magic number; returns the MIME type or null. */
export function sniffImageType(bytes: Uint8Array): string | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "image/png";
  if (bytes.length >= 12) {
    const box = String.fromCharCode(...bytes.slice(4, 8));
    const brand = String.fromCharCode(...bytes.slice(8, 12));
    if (box === "ftyp" && ["heic", "heix", "hevc", "mif1", "msf1"].includes(brand)) return "image/heic";
  }
  if (bytes.length >= 4 && String.fromCharCode(...bytes.slice(0, 4)) === "%PDF") return "application/pdf";
  return null;
}

export { fractionDigits };
