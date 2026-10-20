// Invoked every minute by pg_cron (see migration 600) with the service-role key.
// Drains the storage cleanup queue and dispatches pending push notifications.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { errorResponse, json } from "../_shared/http.ts";
import { adminClient, requireServiceRole } from "../_shared/supabase.ts";
import { dispatchPush, drainStorageCleanup } from "../_shared/maintenance.ts";

Deno.serve(async (request) => {
  try {
    requireServiceRole(request);
    const admin = adminClient();
    const removed = await drainStorageCleanup(admin);
    const push = await dispatchPush(admin);
    return json({ removed_objects: removed, push });
  } catch (error) {
    return errorResponse(error);
  }
});
