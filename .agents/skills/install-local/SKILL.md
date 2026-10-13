---
name: install-local
description: Build and install the latest upstream dsh-TUI from this repo onto PATH and the dsh profile. Use for update-from-source, install-local, refresh-the-installed-app, or dsh-tui-latest requests; not for publishing releases or CI.
---

# Install dsh-TUI from source

One command runs the whole flow:

```sh
.agents/skills/install-local/scripts/update-from-source.sh
```

It pulls upstream main (ff-only), runs `pnpm install --frozen-lockfile`, compile + build gates, `npm pack`, `npm install -g`, `dsh plugin --profile dsh-tui add <tgz>`, then verifies both layers report the same version. Idempotent; safe to re-run at the same HEAD. Output is tee'd to `~/.cache/dsh-tui-local/HEAD-<sha>-update.log`.

## Why two installs

The PATH binary is a thin delegating launcher; the full runtime lives in the dsh profile (`~/.dsh/profiles/dsh-tui` by default). The launcher forwards argv to the profile copy, so updating `npm -g` alone changes nothing the TUI executes. `dsh-tui --version` prints both layers and both lines must match — that is the acceptance check, not "npm said install succeeded".

## Known traps (encoded in the script)

- `dsh plugin add`'s pnpm child can finish the install and then idle forever. Disk state is the source of truth: profile `package.json` pinning the tarball plus the installed package version. The script polls that and kills the child once it matches; do not treat a hung process as a failed install.
- Profile-root `cordis.patch.yml` is the user's patch layer — never overwrite or diff-sync it. The package overlay ships inside the installed package copy under `node_modules`.
- `pnpm-workspace.yaml` pins `@deepseek-ai/*` to the host line declared in `src/dsh-adapter/contract.ts`; after a host release bump the contract gate is what tells you.

## Gate failures

`pnpm build` runs ~90 gates. Triage order before skipping: run the failing gate alone; retry with an isolated `HOME`; retry with `NODE_ENV=production` (CI runs gates that way and can be green while local fails). If upstream CI is green on the same commit and the local failure is deterministic, it is an upstream issue — record it, then re-run with `DSH_TUI_SKIP_GATES=1` (compile still runs). Known recurring case: the `verify:terminal-images` HiDPI frame-budget assertion.

## Env knobs

- `DSH_TUI_LOCAL_CACHE` (default `~/.cache/dsh-tui-local`) — tarball and log location
- `DSH_TUI_SKIP_GATES=1` — compile only, skip `verify:build`
- `DSH_TUI_ADD_HANG_SECS` (default 240) — idle seconds before a finished-but-hung `dsh plugin add` is killed
- `DSH_HOME` (default `~/.dsh`) — where the `dsh-tui` profile lives
