// Exact minor-unit conversion for values coming from external sources (AI output, rate providers).
// Mirrors CurrencyCode.fractionDigits / public.currencies.

const ZERO = new Set(["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]);
const THREE = new Set(["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]);

export function fractionDigits(currency: string): number {
  const code = currency.toUpperCase();
  if (ZERO.has(code)) return 0;
  if (THREE.has(code)) return 3;
  return 2;
}

export function isCurrencyCode(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z]{3}$/.test(value);
}

/**
 * Converts a decimal amount (number or string, e.g. 12.5 or "12,50") to integer minor units without
 * binary floating-point rounding errors. Returns null for anything that isn't a finite amount.
 */
export function toMinorUnits(value: unknown, currency: string): number | null {
  if (value === null || value === undefined) return null;
  // Numbers are rendered with one extra digit so float noise (0.1 + 0.2) rounds away correctly.
  const isNumber = typeof value === "number";
  let text = isNumber ? (Number.isFinite(value) ? (value as number).toFixed(fractionDigits(currency) + 1) : "") : String(value).trim();
  if (/e/i.test(text)) text = Number(text).toFixed(fractionDigits(currency) + 1);
  text = text.replace(/[^\d.,-]/g, "");
  // Decimal separator: the last '.' or ',' unless it is a ',' followed by exactly three digits
  // with no '.' present (thousands grouping like "1,234").
  const lastDot = text.lastIndexOf("."), lastComma = text.lastIndexOf(",");
  let decimalIndex = Math.max(lastDot, lastComma);
  if (decimalIndex === lastComma && lastDot < 0 && text.length - lastComma - 1 === 3) decimalIndex = -1;
  let integer = decimalIndex >= 0 ? text.slice(0, decimalIndex) : text;
  const fraction = decimalIndex >= 0 ? text.slice(decimalIndex + 1).replace(/[^\d]/g, "") : "";
  const negative = integer.startsWith("-");
  integer = integer.replace(/[^\d]/g, "");
  if (!integer && !fraction) return null;
  const digits = fractionDigits(currency);
  // Round half away from zero on the first dropped digit.
  const padded = (fraction + "0".repeat(digits + 1)).slice(0, digits + 1);
  let minor = BigInt((integer || "0") + padded.slice(0, digits));
  if (Number(padded[digits]) >= 5) minor += 1n;
  if (minor > 10_000_000_000n) return null;
  return Number(negative ? -minor : minor);
}
