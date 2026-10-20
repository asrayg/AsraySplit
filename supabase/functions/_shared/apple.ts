// Sign in with Apple token revocation (required when deleting accounts created with SIWA).
// Secrets: APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_CLIENT_ID (bundle id / services id), APPLE_PRIVATE_KEY (.p8).
import { optionalEnv } from "./supabase.ts";

function base64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function clientSecret(): Promise<string> {
  const pem = optionalEnv("APPLE_PRIVATE_KEY")!;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: optionalEnv("APPLE_KEY_ID") }));
  const claims = base64url(JSON.stringify({ iss: optionalEnv("APPLE_TEAM_ID"), iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: optionalEnv("APPLE_CLIENT_ID") }));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)));
  return `${header}.${claims}.${base64url(signature)}`;
}

/** Exchanges a fresh authorization code for a refresh token, then revokes it. */
export async function revokeAppleToken(authorizationCode: string): Promise<boolean> {
  const clientId = optionalEnv("APPLE_CLIENT_ID");
  if (!clientId) return false;
  const secret = await clientSecret();
  const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId, client_secret: secret, code: authorizationCode, grant_type: "authorization_code" }),
  });
  if (!tokenResponse.ok) return false;
  const tokens = await tokenResponse.json() as { refresh_token?: string; access_token?: string };
  const token = tokens.refresh_token ?? tokens.access_token;
  if (!token) return false;
  const revoke = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId, client_secret: secret, token, token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token" }),
  });
  return revoke.ok;
}
