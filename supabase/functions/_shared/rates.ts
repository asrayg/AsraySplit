import { HttpError } from "./http.ts";

/** Parses a Frankfurter response ({ amount, base, date, rates: { USD: 1.0825 } }) into an exact rate string. */
export function parseFrankfurter(body: unknown, quote: string): { rate: string; asOf: string } {
  const data = body as { amount?: number; date?: string; rates?: Record<string, number | string> };
  const raw = data?.rates?.[quote];
  const rate = typeof raw === "number" ? raw.toString() : typeof raw === "string" ? raw : "";
  if (!/^\d+(\.\d+)?$/.test(rate) || Number(rate) <= 0 || (data.amount !== undefined && data.amount !== 1)) {
    throw new HttpError(502, "rate_invalid", "The exchange-rate provider returned an invalid rate.");
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(data.date ?? "")) throw new HttpError(502, "rate_invalid", "The exchange-rate provider returned no date.");
  return { rate, asOf: data.date! };
}
