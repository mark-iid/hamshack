# Security policy

This is a personal OS image for one machine. It has no users to protect and no
release to support, so the usual "supported versions" table would be theatre.
What it does have is a **signing key that two of my machines trust implicitly**,
and that is the thing worth writing a policy about.

## The threat model, stated plainly

The build signs the image with cosign. On the shack PC and the laptop,
`/etc/containers/policy.json` trusts that public key ([`cosign.pub`](cosign.pub)),
and `rpm-ostreed-automatic` stages whatever it signs for the next boot — with no
human in the loop.

So the impact of a compromise here is not "a bad commit in a repo". It is
**arbitrary root code on my machines by the next reboot**, arriving through a
channel built to be trusted. Everything below follows from that one fact.

Three ways in, in the order I consider them likely:

1. **A third-party GitHub Action turning malicious.** `build.yml` hands
   `secrets.SIGNING_SECRET` to `blue-build/github-action`. Anything that action
   runs, runs with the key in hand.
2. **An out-of-repo fetch changing under its pin.** `files/scripts/install-*.sh`
   pull binaries — sdrtrunk, Pat, ardopcf — off the network *into* the artifact
   that then gets signed.
3. **The key itself leaking**, from the Actions secret store or from a working
   copy on a machine.

### What already answers each of those

Not aspirations — these are in the tree and you can check them:

1. **Actions are pinned to commit SHAs, never tags** (`build.yml`,
   `fedora-version-bump.yml`). A tag is mutable by whoever owns the repo it
   points into; a SHA is not. Dependabot bumps the SHA and the trailing version
   comment together, weekly and grouped. This is now **enforced by policy**
   (`sha_pinning_required`), not just observed by habit — an unpinned `uses:`
   fails the workflow rather than shipping quietly.

   Worth knowing how far one pin reaches: `blue-build/github-action` is a
   *composite* that internally calls six more actions (free-disk-space,
   setup-buildx, cosign-installer, setup-qemu, slsa-verifier, checkout). So the
   real trust set is nine repos, not three. Pinning blue-build to a SHA freezes
   its `action.yml` and therefore its six pins along with it — which is the
   reason one pin covers the whole chain. All nine were verified full-length SHAs
   on 2026-08-28.
2. **Dependabot PRs are excluded from the build job** (`if: github.actor !=
   'dependabot[bot]'`). A PR that bumps a third-party action must not get to run
   that new action's code with the signing key before a human has read the diff.
   The cost is that action bumps merge without a green build behind them, which
   is acceptable: a broken `main` means "no new image today", and the machines
   keep running the last good signed deployment.
3. **Every out-of-repo fetch is pinned by version *and* SHA256**, and the install
   script fails the build on mismatch. See the header comments in
   `install-sdrtrunk.sh`, `install-pat.sh`, `install-ardopcf.sh` — an unpinned
   fetch would make the signature attest to something nobody reviewed
   (DESIGN §2.6).
4. **The private key is gitignored** (`cosign.key`, `cosign.private`), with secret
   scanning push protection as the backstop for the day it gets saved under some
   other name. **Do not lean on that backstop.** Push protection covers generic
   PEM key blobs — `ec_private_key`, `rsa_private_key`, `generic_private_key` —
   for free on a public repo. But cosign does not write a stock PEM header; it
   writes `-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----`, and whether GitHub's
   generic regex matches that has not been tested here. The wider
   `non_provider_patterns` net needs GitHub Secret Protection, which this repo
   does not have. Treat the gitignore as the control and push protection as luck.
5. **`main` cannot be force-pushed or deleted**, so the history the signature is
   taken over cannot be quietly rewritten. Note what this deliberately does *not*
   do: it does not require pull requests. Self-approving your own PR is a ritual,
   not a control.

Points 4 and 5 are GitHub settings rather than files, so they live in
[`.github/apply-security-settings.sh`](.github/apply-security-settings.sh) —
re-runnable, and it prints the live state at the end. A checkbox in a web UI
leaves nothing behind to review; that script is the audit trail. Run it to
confirm the repo actually matches what this document claims.

### What is deliberately *not* defended

Being honest about this is more useful than an exhaustive-sounding list:

- **PR builds do get the signing key.** `blue-build/github-action` takes
  `cosign_private_key` as a required input with no keyless/OIDC path, and PR
  builds are the depsolve gate that makes the Fedora-bump workflow safe. Fork
  PRs never receive secrets — GitHub withholds them — so this only exposes the
  key to branches pushed by someone who already has write access.
- **`vm/biib-config.toml` contains `password = "test"`.** That is a throwaway
  qcow2 for the boot check. It is not baked into the image, and the real image
  ships sshd disabled.
- **The machine runs with passwordless sudo**, by decision. Physical access to
  the shack PC is root on the shack PC, and that is the intended trust boundary.
- **VARA binds `0.0.0.0:8300/8301` without authentication** under Wine. Known,
  accepted; it is a LAN-local modem on an operating-session-only process.

## Reporting something

Use **[private vulnerability reporting](https://github.com/mark-iid/hamshack/security/advisories/new)**
— the Security tab on this repo. It gives us a private thread before anything is
public, which a GitHub issue does not.

Please don't open a public issue for anything touching the signing key, the build
pipeline, or the pinned installers.

I am one person doing this around a day job. Realistically: I'll acknowledge
within a week, and a fix to the image is a CI build plus a reboot, so remediation
itself is fast once the problem is understood.

**If you find something in the shared session stack** — greetd, niri, the update
model, the bootstrap — it very likely affects the sibling laptop image
[`frameworkimage`](https://github.com/mark-iid/frameworkimage) too. Say so in the
report and I'll fix both.

## Out of scope

- Package vulnerabilities in Fedora or RPM Fusion. Report those upstream; this
  repo installs them, it doesn't maintain them.
- Anything requiring physical access to the shack PC — see passwordless sudo
  above.
- The ham applications themselves (WSJT-X, fldigi, Pat, VARA…). Upstream them.
  The one exception is if *this repo's packaging or configuration* is what
  introduces the exposure.
