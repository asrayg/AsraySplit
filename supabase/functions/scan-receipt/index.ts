import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const headers = { "Content-Type": "application/json" };

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers });
  try {
    const { imageBase64, mimeType = "image/jpeg" } = await request.json();
    if (!imageBase64 || imageBase64.length > 14_000_000) return new Response(JSON.stringify({ error: "A receipt image under 10MB is required" }), { status: 400, headers });
    const apiKey = Deno.env.get("OPENAI_API_KEY");
    if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");
    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("RECEIPT_MODEL") ?? "gpt-4.1-mini",
        input: [{ role: "user", content: [
          { type: "input_text", text: "Extract this receipt. Preserve every purchased line item. Prices are line totals. Use ISO 8601 date-time for date and valid UUID strings for item ids. Return only JSON matching the schema. Never invent unreadable values." },
          { type: "input_image", image_url: `data:${mimeType};base64,${imageBase64}`, detail: "high" }
        ]}],
        text: { format: { type: "json_schema", name: "receipt", strict: true, schema: {
          type: "object", additionalProperties: false,
          properties: {
            merchant: { type: "string" }, date: { type: "string" },
            items: { type: "array", items: { type: "object", additionalProperties: false, properties: { id: { type: "string" }, name: { type: "string" }, quantity: { type: "integer" }, price: { type: "number" }, assigned_to: { type: "array", items: { type: "string" } } }, required: ["id","name","quantity","price","assigned_to"] } },
            subtotal: { type: "number" }, tax: { type: "number" }, tip: { type: "number" }, discount: { type: "number" }, currency: { type: "string" }, confidence: { type: "number" }, raw_text: { type: "string" }
          }, required: ["merchant","date","items","subtotal","tax","tip","discount","currency","confidence","raw_text"]
        } } }
      })
    });
    if (!response.ok) throw new Error(`AI provider error: ${response.status}`);
    const result = await response.json();
    const output = result.output?.flatMap((x: any) => x.content ?? []).find((x: any) => x.type === "output_text")?.text;
    if (!output) throw new Error("AI returned no receipt data");
    return new Response(output, { headers });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Scan failed" }), { status: 500, headers });
  }
});

