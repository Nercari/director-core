#!/usr/bin/env bash
# exec-jail — run an executor with the gate credentials removed from its
# environment. Blueprint §8.3, §21.8.
#
# WHAT THIS DOES AND DOES NOT DO. Read before relying on it.
#
# DOES (probed 2026-07-26, both verified):
#   gh auth status  -> "You are not logged into any GitHub hosts"
#   gh api user     -> "please run gh auth login"
#   git push        -> "fatal: could not read Username ... terminal prompts disabled"
#   Baseline for comparison: push --dry-run reported "* [new branch]", i.e. it
#   would have pushed. So the executor cannot push, open a pull request, or merge.
#
# DOES NOT:
#   Block network egress. DNS resolves and public reads still work — verified,
#   `git ls-remote` against a public repo succeeds because that needs no
#   credentials. An executor can still fetch, and could still exfiltrate.
#   Closing that needs §21.8's account-scoped firewall rule, which is an
#   operating-system change and belongs to the operator.
#
# So this is a real control over THE GATE and no control at all over the network.
# Do not describe it as isolation. The distinction is the whole point of the
# §8.3 correction: name exactly what is enforced.
#
# Usage: exec-jail.sh <command> [args...]
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: exec-jail.sh <command> [args...]" >&2
  exit 2
fi

JAIL="${TMPDIR:-/tmp}/director-exec-jail.$$"
mkdir -p "$JAIL/ghconfig"
: > "$JAIL/gitconfig-null"
trap 'rm -rf "$JAIL"' EXIT

# GH_CONFIG_DIR is the load-bearing one: gh reads its host credentials from
# there, so an empty directory leaves it unauthenticated even though the real
# keyring entry still exists for the operator's own shell.
#
# GIT_CONFIG_GLOBAL and _SYSTEM are nulled so no credential helper is reachable.
# A repo-level helper in .git/config would survive this — check for one before
# trusting the jail on a repository you did not create.
#
# Nulling the global config also removes a global-only Git identity. Set a
# distinct executor identity explicitly. This does NOT enable executor commits:
# the workspace-write sandbox still denies .git/worktrees/<wt>/index.lock. It
# is defensive for a future mode in which .git is deliberately writable.
#
# GIT_TERMINAL_PROMPT=0 and GCM_INTERACTIVE=never turn a credential prompt into
# an immediate failure rather than a hang. Without them a jailed push blocks
# waiting for a username that will never be typed.
#
# SSH agent variables are removed and Git is forced to a refusing SSH command.
# This is defensive: no SSH agent or keys were present in the reproduced hole,
# but a future agent must not turn an SSH remote into a bypass.
exec env \
  -u GH_TOKEN \
  -u GITHUB_TOKEN \
  -u GH_ENTERPRISE_TOKEN \
  -u GITHUB_ENTERPRISE_TOKEN \
  -u SSH_AUTH_SOCK \
  -u SSH_AGENT_PID \
  GH_CONFIG_DIR="$JAIL/ghconfig" \
  GIT_CONFIG_GLOBAL="$JAIL/gitconfig-null" \
  GIT_CONFIG_SYSTEM="$JAIL/gitconfig-null" \
  GIT_AUTHOR_NAME=director-executor \
  GIT_AUTHOR_EMAIL=executor@director.local \
  GIT_COMMITTER_NAME=director-executor \
  GIT_COMMITTER_EMAIL=executor@director.local \
  GIT_TERMINAL_PROMPT=0 \
  GCM_INTERACTIVE=never \
  GIT_SSH_COMMAND=/bin/false \
  "$@"
