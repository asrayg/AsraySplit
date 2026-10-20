// POST { base, quote, date } -> { base, quote, rate, provider, as_of }
// Rates come from the European Central Bank reference rates via the Frankfurter API (free, no key,
// published ~16:00 CET on business days). Results are cached in public.exchange_rates. Every expense
// stores the rate it used, so later updates never change historical totals.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { errorResponse, HttpError, json, log, readJson } from "../_shared/http.ts";
import { adminClient, requireUser, userClient } from "../_shared/supabase.ts";
import { parseFrankfurter } from "../_shared/rates.ts";

const PROVIDER = "ecb";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ code: "method_not_allowed", message: "Use POST." }, 405);
  try {
    await requireUser(userClient(request));
    const body = await readJson<{ base?: string; quote?: string; date?: string }>(request);
    const base = (body.base ?? "").toUpperCase(), quote = (body.quote ?? "").toUpperCase();
    if (!/^[A-Z]{3}$/.test(base) || !/^[A-Z]{3}$/.test(quote)) throw new HttpError(400, "invalid_currency", "Use ISO currency codes.");
    const today = new Date().toISOString().slice(0, 10);
    let date = /^\d{4}-\d{2}-\d{2}$/.test(body.date ?? "") ? body.date! : today;
    if (date > today) date = today;
    if (base === quote) return json({ base, quote, rate: "1", provider: "identity", as_of: date });

    const admin = adminClient();
    const cached = await admin.from("exchange_rates").select("rate, as_of").eq("base", base).eq("quote", quote).eq("provider", PROVIDER)
      .lte("as_of", date).order("as_of", { ascending: false }).limit(1).maybeSingle();
    // Cached rate for the requested day (or the last business day within 4 days of it).
    if (cached.data && (Date.parse(date) - Date.parse(cached.data.as_of)) <= 4 * 86_400_000) {
      return json({ base, quote, rate: String(cached.data.rate), provider: PROVIDER, as_of: cached.data.as_of });
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8_000);
    try {
      const response = await fetch(`https://api.frankfurter.app/${date}?from=${base}&to=${quote}`, { signal: controller.signal });
      if (response.status === 404 || response.status === 422) throw new HttpError(404, "rate_unavailable", "No published rate for this currency. Enter it manually.");
      if (!response.ok) throw new HttpError(503, "rate_provider_unavailable", "Exchange rates are unavailable. Enter the rate manually.");
      const parsed = parseFrankfurter(await response.json(), quote);
      await admin.from("exchange_rates").upsert({ base, quote, as_of: parsed.asOf, provider: PROVIDER, rate: parsed.rate });
      log("exchange_rate", { base, quote, as_of: parsed.asOf });
      return json({ base, quote, rate: parsed.rate, provider: PROVIDER, as_of: parsed.asOf });
    } finally {
      clearTimeout(timer);
    }
  } catch (error) {
    if ((error as Error).name === "AbortError") return json({ code: "rate_provider_timeout", message: "Exchange rates are unavailable. Enter the rate manually." }, 504);
    return errorResponse(error);
  }
});
