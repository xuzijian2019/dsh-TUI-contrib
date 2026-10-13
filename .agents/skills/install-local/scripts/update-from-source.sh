#!/usr/bin/env bash
# update-from-source.sh — one-shot maintainer flow: pull upstream main, build,
# pack, and install dsh-tui onto PATH (npm -g) and the dsh profile.
#
# Idempotent: safe to re-run at the same HEAD. Non-obvious traps are encoded
# here on purpose (see SKILL.md next to this script):
#   - the PATH binary is a thin launcher; the real runtime lives in the dsh
#     profile, so BOTH installs must land;
#   - `dsh plugin add` may finish its install and then idle forever; on-disk
#     profile state is the source of truth, and the child is killed once the
#     state matches;
#   - all output is tee'd to a log file, never buffered through a pipe tail,
#     so a hang stays observable while it happens.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cache="${DSH_TUI_LOCAL_CACHE:-$HOME/.cache/dsh-tui-local}"
dsh_home="${DSH_HOME:-$HOME/.dsh}"
add_hang_secs="${DSH_TUI_ADD_HANG_SECS:-240}"
sha="$(git -C "$repo_root" rev-parse --short HEAD)"
profile_dir="$dsh_home/profiles/dsh-tui"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

mkdir -p "$cache/packages"
log="$cache/HEAD-$sha-update.log"
exec > >(tee -a "$log") 2>&1
echo "log: $log"

step '1/7 pull upstream main (ff-only)'
git -C "$repo_root" pull --ff-only || die 'pull failed — resolve local state first'
git -C "$repo_root" log --oneline -1

step '2/7 pnpm install --frozen-lockfile (prepare compiles vendor + lib)'
(cd "$repo_root" && pnpm install --frozen-lockfile) || die 'pnpm install failed'

step '3/7 compile + build gates'
if [ "${DSH_TUI_SKIP_GATES:-0}" = 1 ]; then
  (cd "$repo_root" && pnpm compile) || die 'compile failed'
  echo 'verify:build skipped via DSH_TUI_SKIP_GATES=1 (known upstream gate failure path)'
else
  (cd "$repo_root" && pnpm build) || die 'build gates failed — triage: run the failing gate alone, then with an isolated HOME, then NODE_ENV=production (CI parity); see SKILL.md'
fi

step '4/7 npm pack'
version="$(node -p "require('$repo_root/package.json').version")"
pack_dir="$(mktemp -d "$cache/packages/HEAD-$sha-XXXX")"
tgz_name="$( (cd "$repo_root" && npm pack --pack-destination "$pack_dir") | tail -1 )"
tgz="$pack_dir/$tgz_name"
[ -f "$tgz" ] || die 'npm pack produced no tarball'
echo "packed: $tgz"

step '5/7 npm install -g (PATH launcher)'
npm install -g "$tgz" >/dev/null || die 'npm install -g failed'
echo "global launcher -> $version"

step '6/7 dsh plugin --profile dsh-tui add (profile runtime)'
profile_state_ready() {
  grep -qs "\"@deepseek-harness-tui/dsh-tui\": \"file:$tgz\"" "$profile_dir/package.json" || return 1
  [ "$(node -p "try { require('$profile_dir/node_modules/@deepseek-harness-tui/dsh-tui/package.json').version } catch { }")" = "$version" ]
}
dsh plugin --profile dsh-tui add "$tgz" >"$pack_dir/plugin-add.log" 2>&1 &
add_pid=$!
started=$SECONDS
while kill -0 "$add_pid" 2>/dev/null; do
  elapsed=$((SECONDS - started))
  if profile_state_ready && [ "$elapsed" -ge "$add_hang_secs" ]; then
    kill "$add_pid" 2>/dev/null || true
    wait "$add_pid" 2>/dev/null || true
    echo "profile state complete; killed idle dsh plugin add after ${elapsed}s (known post-install hang)"
    break
  fi
  if [ "$elapsed" -ge 900 ]; then
    tail -20 "$pack_dir/plugin-add.log" >&2 || true
    die "dsh plugin add made no progress in 900s and profile state is incomplete (log: $pack_dir/plugin-add.log)"
  fi
  sleep 10
done
wait "$add_pid" 2>/dev/null || true
profile_state_ready || {
  tail -20 "$pack_dir/plugin-add.log" >&2 || true
  die "profile state incomplete after dsh plugin add (log: $pack_dir/plugin-add.log)"
}
echo "profile runtime -> $version"

step '7/7 verify both layers'
out="$(dsh-tui --version)" || die 'dsh-tui --version failed'
printf '%s\n' "$out"
matches="$(printf '%s\n' "$out" | grep -c "$version" || true)"
[ "$matches" -ge 2 ] || die "launcher/profile version mismatch — expected $version on both lines"
echo "OK: dsh-tui $version on PATH and in the profile"
