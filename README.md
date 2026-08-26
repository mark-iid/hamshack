# kb3lyb-shack

A personal [Fedora Sway Atomic](https://fedoraproject.org/atomic-desktops/sway/)
image, built with [BlueBuild](https://blue-build.org/) and tailored for an
**HP EliteDesk 800 G4 Mini** running the ham shack, in a **niri** session tuned
so that ham software floats instead of tiling.

It is a sibling of [`frameworkimage`](https://github.com/mark-iid/frameworkimage)
(`kb3lyb-sway`, the Framework 13 laptop) and shares its session stack, its update
model and most of its tooling. It exists as a separate repo so that a broken
shack build cannot red-X the laptop, and so that neither image's recipe has to
carry `if this machine` conditionals.

The point of building it at all is the same as the laptop's: the fragile parts —
the codec swap, three dozen ham packages across a Fedora version bump, two
out-of-repo installs — get resolved in CI, where failure means "no new image
today" and the shack keeps running the last good one.

> This is a personal image for one specific machine. Read it, fork it, borrow from
> it, but hardware choices, display layout and package selection are all
> EliteDesk-800-G4-and-this-operator specific.

## What's inside

**Ham radio** — the reason this repo exists. Isolated in
[`recipes/common/hamradio.yml`](recipes/common/hamradio.yml) and depsolve-tested
on its own via [`recipes/ham-test.yml`](recipes/ham-test.yml).

| Group | Packages |
|---|---|
| Rig control | hamlib (`rigctl`/`rigctld`/`rotctld`), flrig |
| Weak-signal digital | WSJT-X, JS8Call |
| fldigi suite | fldigi, flmsg, flamp, qsstv |
| Packet / APRS / Winlink | direwolf, ax25-tools/apps, xastir, **Pat** |
| SDR | rtl-sdr, SoapySDR (+rtlsdr/airspyhf), gqrx, SDR++, SDRangel, rtl_433, **sdrtrunk** |
| Logging / awards | CQRLOG, KLog, TrustedQSL (`tqsl`) |
| Programming | **chirp+wx**, Wine (incl. 32-bit) for the RT Systems programmers |
| Satellites | gpredict |

Almost all of it comes from Fedora proper. Three items do not, and each is
handled explicitly rather than hopefully:

- **sdrtrunk** — packaged nowhere. Installed from the upstream jlink zip at a
  pinned version + SHA256, into `/usr/lib/opt` (see below).
- **Pat** (Winlink) — no RPM exists. Single Go binary, pinned + checksummed.
- **GridTracker** — packaged nowhere and `$HOME`-shaped. Deliberately *not* baked;
  it belongs to the dotfiles bootstrap, same rule that keeps brew out of the image.

**Session:** niri + xwayland-satellite, greetd + tuigreet, waybar, mako, fuzzel,
gtklock, kanshi, foot, grim/slurp, cliphist — the laptop's stack minus the
battery and backlight pieces.

**Codecs:** RPM Fusion `ffmpeg` swap plus `intel-media-driver` for VA-API.

**System:** Tailscale + sshd for remote admin; no remote GUI, by decision.

## The three things most likely to bite

Documented here because each one produces a **green build and a broken machine**,
which is the worst failure shape there is. All three are asserted at build time by
[`files/scripts/image-assert.sh`](files/scripts/image-assert.sh).

1. **`chirp` is not CHIRP.** The plain package installs `/usr/bin/chirpc`, a CLI.
   The wxPython GUI lives in **`chirp+wx`**.
2. **`wine` is x86_64-only.** On Fedora 44 the metapackage pulls no i686 packages
   at all, and RT Systems programmers are 32-bit. `wine-core.i686` is listed
   explicitly; it takes the transaction from ~120 packages to 733.
3. **`/opt` is a symlink to `/var/opt`.** On this ostree base `/var` is machine
   state, not image content — anything written to `/opt` (or `/usr/local`) during
   a build is silently discarded at commit. Image-side installs go to
   `/usr/lib/opt`, with a tmpfiles symlink back to `/opt` at boot.

## Documentation

- **[DESIGN.md](DESIGN.md)** — what is built and why: the decisions, what differs
  from the laptop image and for what reason, and the open questions (Wine and RT
  Systems chief among them).
- **[SETUP.md](SETUP.md)** — the operations runbook: local build loop, VM testing,
  ISO, install, first boot, and the per-machine steps the image cannot do for you.

## Differences from `kb3lyb-sway` (the laptop)

| | kb3lyb-sway | kb3lyb-shack |
|---|---|---|
| Hardware | Framework 13, AMD Ryzen | EliteDesk 800 G4 Mini, Coffee Lake |
| VA-API driver | `mesa-va-drivers-freeworld` (RPM Fusion **free**) | `intel-media-driver` (RPM Fusion **nonfree**) |
| Display | one 2256x1504 panel @ 1.35 scale | multi-head @ 1x |
| niri layout | tiling throughout | tiling, with ham apps ruled **floating** |
| Auth | fprintd fingerprint for sudo + lock | password only |
| Power | AC/battery profile switching | none — it is on mains |
| Network | Wi-Fi + Tailscale | wired + Tailscale |
| Apps | dev tooling, Evolution, many Flatpaks | the same, plus the ham stack, minus kismet/HandBrake/Boxes |
| `$HOME` bootstrap | brew, SDKMAN, JetBrains Toolbox, voice toolbox | brew only |

## Installation

> [!WARNING]
> Read DESIGN §"Clean install" before pointing this at real hardware.

```bash
# 1. Rebase to the unsigned image first, to pull in the signing keys + policy:
rpm-ostree rebase ostree-unverified-registry:ghcr.io/mark-iid/kb3lyb-shack:latest
systemctl reboot

# 2. Then rebase to the signed image:
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mark-iid/kb3lyb-shack:latest
systemctl reboot
```

For a clean install, generate an installer ISO — see SETUP §4 and [`vm/`](vm/).

> [!CAUTION]
> The generated `anaconda-iso` is **unattended by default and will silently wipe
> the first disk it finds.** The tooling here forces an interactive install via an
> empty kickstart; never build the ISO without it.

## Repository layout

| Path | What it is |
|---|---|
| `recipes/recipe.yml` | The image definition. |
| `recipes/common/hamradio.yml` | The ham stack, isolated and separately testable. |
| `recipes/common/codecs.yml` | RPM Fusion + ffmpeg + Intel VA-API. |
| `recipes/ham-test.yml`, `recipes/codec-test.yml` | Standalone depsolve smoke tests. |
| `files/system/` | Files baked into the image root (niri, greetd, waybar, ...). |
| `files/scripts/` | Build-time scripts, incl. the out-of-repo installers. |
| `files/scripts/image-assert.sh` | Build-time postconditions. |
| `vm/` | Local build + VM test + ISO build tooling. |
| `.github/workflows/` | Nightly build and the Fedora version-bump PR workflow. |

## Verification

Images are signed with [cosign](https://github.com/sigstore/cosign):

```bash
cosign verify --key cosign.pub ghcr.io/mark-iid/kb3lyb-shack
```

## License

See [LICENSE](LICENSE).
