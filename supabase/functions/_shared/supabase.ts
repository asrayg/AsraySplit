import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new HttpError(500, "not_configured", `${name} is not configured.`);
  return value;
}

/** Client acting as the calling user: RLS and RPC membership checks apply. */
export function userClient(request: Request): SupabaseClient {
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) throw new HttpError(401, "not_authenticated", "Sign in to continue.");
  return createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Service-role client. Only for work the user is not allowed to do directly, after authorization. */
export function adminClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function requireUser(client: SupabaseClient): Promise<{ id: string; email?: string; appMetadata: Record<string, unknown> }> {
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new HttpError(401, "not_authenticated", "Sign in to continue.");
  return { id: data.user.id, email: data.user.email, appMetadata: data.user.app_metadata ?? {} };
}

/** For scheduled/internal functions: the caller must present the service-role key. */
export function requireServiceRole(request: Request): void {
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/, "") ?? "";
  if (!token || token !== Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) throw new HttpError(401, "not_authorized", "Service credentials required.");
}

export function optionalEnv(name: string): string | undefined {
  return Deno.env.get(name) || undefined;
}
