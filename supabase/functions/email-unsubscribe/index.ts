// GET/POST ?u=<user id>&s=<signature> — one-click unsubscribe from reminder emails (RFC 8058).
// The signature is an HMAC of the user id, so links can't be forged for other users.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { UUID_PATTERN, log } from "../_shared/http.ts";
import { adminClient, optionalEnv } from "../_shared/supabase.ts";
import { verifyUnsubscribe } from "../_shared/email.ts";

const page = (message: string, status = 200) => new Response(
  `<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Asray Split</title></head>
<body style="font-family:-apple-system,system-ui,sans-serif;max-width:480px;margin:64px auto;padding:0 16px;text-align:center"><p>${message}</p></body></html>`,
  { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const userId = url.searchParams.get("u") ?? "", signature = url.searchParams.get("s") ?? "";
  const secret = optionalEnv("EMAIL_LINK_SECRET");
  if (!secret || !UUID_PATTERN.test(userId) || !(await verifyUnsubscribe(userId, signature, secret))) {
    return page("This unsubscribe link isn’t valid. You can turn off reminder emails in the app under Settings → Notifications.", 400);
  }
  const { error } = await adminClient().rpc("disable_email_reminders", { p_user_id: userId });
  if (error) return page("Something went wrong. Please try again, or turn off reminder emails in the app.", 500);
  log("email_unsubscribed", {});
  return page("You won’t get reminder emails from Asray Split anymore. You can turn them back on in Settings → Notifications.");
});
