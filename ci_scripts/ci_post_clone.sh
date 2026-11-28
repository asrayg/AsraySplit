#!/bin/sh
# Xcode Cloud: runs after cloning. Writes the git-ignored Supabase config from workflow environment variables
# (Xcode Cloud › Workflow › Environment: SUPABASE_HOST, SUPABASE_PUBLISHABLE_KEY — publishable key only).
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
if [ -z "${SUPABASE_HOST:-}" ] || [ -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]; then
  echo "warning: SUPABASE_HOST / SUPABASE_PUBLISHABLE_KEY not set; the build will run in demo mode" >&2
  exit 0
fi
for config in Debug Staging Release; do
  printf 'SUPABASE_HOST = %s\nSUPABASE_PUBLISHABLE_KEY = %s\n' "$SUPABASE_HOST" "$SUPABASE_PUBLISHABLE_KEY" > "Config/Secrets.$config.xcconfig"
done
echo "Wrote Supabase config for $SUPABASE_HOST"
