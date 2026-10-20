// POST { apple_authorization_code? } -> 204
// In-app account deletion (App Store guideline 5.1.1(v)):
// 1. As the user: public.prepare_account_deletion() hands shared trips to another member, deletes
//    solo trips, anonymizes participant labels and queues the user's receipt images for deletion.
// 2. Service role: removes queued storage objects, revokes Sign in with Apple tokens, deletes the auth
//    user (cascading profile, memberships, devices, preferences and usage records).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { errorResponse, fromPostgrest, json, log, readJson } from "../_shared/http.ts";
import { adminClient, optionalEnv, requireUser, userClient } from "../_shared/supabase.ts";
import { drainStorageCleanup } from "../_shared/maintenance.ts";
import { revokeAppleToken } from "../_shared/apple.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ code: "method_not_allowed", message: "Use POST." }, 405);
  try {
    const client = userClient(request);
    const user = await requireUser(client);
    const body = await readJson<{ apple_authorization_code?: string }>(request);

    const prepared = await client.rpc("prepare_account_deletion");
    const prepareError = fromPostgrest(prepared.error);
    if (prepareError) throw prepareError;

    const admin = adminClient();
    await drainStorageCleanup(admin, 1000);

    let appleRevoked = false;
    if (body.apple_authorization_code && optionalEnv("APPLE_PRIVATE_KEY")) {
      appleRevoked = await revokeAppleToken(body.apple_authorization_code).catch(() => false);
    }

    const { error } = await admin.auth.admin.deleteUser(user.id);
    if (error) throw error;
    log("account_deleted", { trips_deleted: prepared.data?.trips_deleted, trips_transferred: prepared.data?.trips_transferred, apple_revoked: appleRevoked });
    return new Response(null, { status: 204 });
  } catch (error) {
    return errorResponse(error);
  }
});
