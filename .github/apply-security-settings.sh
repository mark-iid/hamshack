#!/usr/bin/env bash
# apply-security-settings.sh — put this repo's GitHub security settings in the tree
# instead of in a web UI nobody can diff.
#
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST: every one of these settings is a
# checkbox on github.com that leaves no trace in the repo. Six months from now
# there is no way to tell whether push protection was ever on, or whether someone
# turned it off to land one commit and forgot. Written down and re-runnable, the
# answer is `git log` plus one command.
#
# Idempotent — safe to re-run. It only reports what it changed.
#
# Needs an admin token:  gh auth login   (scopes: repo, security_events, admin:org
#                                         is NOT needed for a user-owned repo)
#
# See SECURITY.md for WHY each of these matters here; the short version is that
# this repo signs an OS image two machines auto-trust, so the build pipeline is
# the asset, not the source.
set -euo pipefail

REPO="${1:-mark-iid/hamshack}"
api() { gh api -H "Accept: application/vnd.github+json" "$@"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

command -v gh >/dev/null || { echo "gh not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run: gh auth login" >&2; exit 1; }

echo "==> $REPO"

# --- 1. Secret scanning + push protection ----------------------------------
# The cosign PRIVATE key is gitignored as cosign.key / cosign.private. That
# handles the two names it actually has; push protection handles the day it gets
# exported as something else, which is the realistic failure. Push protection is
# the half that matters — plain secret scanning tells you after the fact, and for
# a signing key "after the fact" means rotating the key and re-signing.
#
# GENERIC PRIVATE KEYS ARE COVERED FOR FREE on a public repo: ec_private_key,
# rsa_private_key, openssh_private_key and generic_private_key all carry push
# protection at no cost. So a stock PEM key blob does get blocked at push time.
#
# non_provider_patterns is a WIDER net and needs GitHub Secret Protection, which
# this repo does not have — it stays "disabled" no matter what we send. Recorded
# here so nobody spends an afternoon on it. The gap that leaves is narrow but
# real, and it is written up in SECURITY.md rather than papered over.
#
# READ THE STATE BACK, do not trust the 200. GitHub accepts a PATCH enabling a
# feature your plan does not include and returns success with the field still
# "disabled" — no error, no warning. The first version of this script printed a
# green tick for non_provider_patterns while the repo had it off. Anything that
# reports success without reading back the result is how a security setting ends
# up believed-on and actually-off.
echo "-- secret scanning"
api -X PATCH "repos/$REPO" -F 'security_and_analysis[secret_scanning][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
  -F 'security_and_analysis[secret_scanning_non_provider_patterns][status]=enabled' \
  >/dev/null 2>&1 || true
for f in secret_scanning secret_scanning_push_protection secret_scanning_non_provider_patterns; do
  st=$(api "repos/$REPO" --jq ".security_and_analysis.${f}.status // \"absent\"")
  if [ "$st" = enabled ]; then ok "$f: $st"; else warn "$f: $st"; fi
done

# --- 2. Dependabot ----------------------------------------------------------
# Modest value here: the only ecosystem in this repo is github-actions, since
# there are no package manifests. But it is free and .github/dependabot.yml
# already groups bumps into one weekly PR, so it adds no noise.
#
# Note the interaction with build.yml: Dependabot PRs are excluded from the build
# job on purpose (they must not run new third-party action code with the signing
# key). So these PRs arrive without a green build — that is by design, and the
# reasoning is in build.yml and SECURITY.md.
echo "-- dependabot"
api -X PUT "repos/$REPO/vulnerability-alerts"     >/dev/null && ok "alerts enabled"
api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null && ok "security updates enabled"

# --- 3. CodeQL, actions analysis -------------------------------------------
# THE HIGH-VALUE ONE. This repo is shell and YAML; CodeQL analyses neither as
# "code" — but its `actions` pack (GA since 2025-04) reads workflows and finds
# script injection, over-broad permissions and unpinned action references. Those
# are precisely the three ways the signing key gets stolen (SECURITY.md).
#
# `default` rather than `extended`: extended trades false positives for recall,
# and on two workflow files a noisy scanner just gets ignored.
echo "-- code scanning"
if api -X PATCH "repos/$REPO/code-scanning/default-setup" \
     -f state=configured -f query_suite=default -f 'languages[]=actions' >/dev/null 2>&1
then
  ok "CodeQL default setup: actions"
else
  warn "code scanning unchanged (already configured, or advanced setup in use)"
fi

# --- 4. Private vulnerability reporting ------------------------------------
# Gives a private thread before disclosure. Without it the only channel is a
# public issue, which for a build-pipeline bug means publishing the attack before
# there is a fix. Pairs with the reporting link in SECURITY.md.
echo "-- private vulnerability reporting"
api -X PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null && ok "enabled"

# --- 5. Default GITHUB_TOKEN scope -----------------------------------------
# Both workflows declare their own `permissions:` block, and an explicit block
# still applies when the repo default is restricted (the "can't grant write"
# caveat applies to FORKED repos only). So this changes nothing about what the
# current workflows can do — it changes what the NEXT workflow gets if someone
# adds one and forgets a permissions block. Defense in depth, zero cost.
#
# can_approve_pull_request_reviews=false: stops a workflow self-approving a PR,
# which would defeat any review requirement added later.
echo "-- default workflow token"
api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false \
  >/dev/null && ok "read-only by default, cannot approve PRs"

# --- 5b. Require SHA-pinned actions ----------------------------------------
# Every `uses:` in this repo is already pinned to a full-length commit SHA, by
# hand and by convention (see the note in build.yml). This makes the convention
# ENFORCED: an unpinned action now fails the workflow instead of quietly
# shipping. Convention holds until the day someone is in a hurry; policy doesn't
# care how busy anyone is.
#
# Safe to switch on here — verified before enabling that all nine references
# comply: the 3 direct ones, plus the 6 that blue-build/github-action calls
# internally (it is a composite: free-disk-space, setup-buildx, cosign-installer,
# setup-qemu, slsa-verifier, checkout). Those six are pinned by blue-build, and
# our SHA pin on blue-build freezes its action.yml along with them — which is why
# one pin covers the whole chain.
#
# This is NOT the same control as an allow-list. It governs HOW an action is
# referenced, not WHICH actions may run. Adding an allow-list is still open; see
# the note at the end.
echo "-- SHA pinning policy"
api -X PUT "repos/$REPO/actions/permissions" --input - >/dev/null <<'JSON'
{ "enabled": true, "allowed_actions": "all", "sha_pinning_required": true }
JSON
pin=$(api "repos/$REPO/actions/permissions" --jq '.sha_pinning_required')
if [ "$pin" = true ]; then ok "actions must be pinned to a full-length SHA"
else warn "sha_pinning_required: $pin"; fi

# --- 6. Fork PR approval ----------------------------------------------------
# Fork PRs never receive secrets — GitHub withholds them — so the signing key is
# not at risk here. What this stops is a stranger's PR spending 45 minutes of
# runner time on an image build, on a public repo, unattended.
echo "-- fork PR approval"
api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
  -f approval_policy=all_external_contributors \
  >/dev/null && ok "all external contributors require approval"

# --- 7. Protect main --------------------------------------------------------
# DELIBERATELY NOT "require a pull request". This is a one-operator repo that
# works by pushing to main; a review requirement you satisfy by approving your
# own PR is a ritual, not a control, and it would break the direct-push workflow
# for nothing.
#
# What IS worth having: main cannot be force-pushed or deleted. The signature
# attests to a build of a particular tree, so silently rewriting the history that
# tree came from is the one git-level operation with real consequences here.
echo "-- main branch ruleset"
if api "repos/$REPO/rulesets" --jq '.[].name' 2>/dev/null | grep -qx 'protect-main'; then
  ok "ruleset 'protect-main' already present"
else
  api -X POST "repos/$REPO/rulesets" --input - >/dev/null <<'JSON' && ok "ruleset 'protect-main' created"
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [ { "type": "non_fast_forward" }, { "type": "deletion" } ]
}
JSON
fi

echo
echo "==> current state"
api "repos/$REPO" --jq '.security_and_analysis
  | to_entries[] | "  \(.key): \(.value.status)"' 2>/dev/null || true
printf '  default_workflow_permissions: %s\n' \
  "$(api "repos/$REPO/actions/permissions/workflow" --jq '.default_workflow_permissions')"
printf '  private_vulnerability_reporting: %s\n' \
  "$(api "repos/$REPO/private-vulnerability-reporting" --jq '.enabled')"
printf '  code_scanning_default_setup: %s\n' \
  "$(api "repos/$REPO/code-scanning/default-setup" --jq '.state' 2>/dev/null || echo unknown)"
printf '  sha_pinning_required: %s\n' \
  "$(api "repos/$REPO/actions/permissions" --jq '.sha_pinning_required')"
echo
echo "Still open, deliberately — it needs a judgement call, not a default:"
echo "  * Actions ALLOW-LIST (allowed_actions: selected). Different control from"
echo "    SHA pinning: pinning governs how an action is referenced, the allow-list"
echo "    governs which may run at all. It is the only thing that stops a NEW"
echo "    unreviewed 'uses:' appearing in the job that holds the signing key."
echo "    Not enabled because GitHub does not document whether the policy is"
echo "    enforced against actions called INSIDE a composite. blue-build is a"
echo "    composite calling 6 more, so the list is either 3 entries or 9, and if"
echo "    it is 9 a routine blue-build bump breaks the build at an unrelated"
echo "    moment. To settle it: set allowed_actions=selected with the 3 direct"
echo "    entries, run a workflow_dispatch build, and see. A red build costs only"
echo "    'no new image today' (DESIGN §5), so the experiment is cheap."
