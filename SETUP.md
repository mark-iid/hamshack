# kb3lyb-shack — setup & operations runbook

Design rationale lives in [DESIGN.md](DESIGN.md). This is the "how do I actually
do it" file.

---

## 1. One-time GitHub / CI setup

1. Create the GitHub repo and push.
2. Generate a signing keypair — **this repo has no `cosign.pub` yet**, and the
   build will not sign without one:

   ```bash
   podman run --rm -it -v "$PWD":/build:Z -w /build \
     ghcr.io/blue-build/cli:latest bluebuild new --help   # or:
   cosign generate-key-pair
   ```

   Commit `cosign.pub`. Put the private key in the repo's Actions secrets as
   **`SIGNING_SECRET`**. `.gitignore` already excludes `cosign.key` /
   `cosign.private` — keep it that way.
3. Under *Settings → Actions → General*, allow workflows to write packages.
4. After the first successful build, make the GHCR package public (or the machine
   cannot pull it without auth).

Dependabot PRs deliberately do not build — they would need the signing key, and we
do not want an unreviewed third-party action bump running with it in hand.

---

## 2. Local build loop

Iterate locally, not through GitHub Actions.

```bash
./build-local.sh                          # full image     -> kb3lyb-shack:44
./build-local.sh recipes/ham-test.yml     # ham stack only -> kb3lyb-ham-test:44
./build-local.sh recipes/codec-test.yml   # codecs only    -> kb3lyb-codec-test:44
```

Tags are **derived from the recipe** (`name` + `image-version`), never hardcoded,
so an automated Fedora bump cannot leave the local build tagging new bits with the
old version. Same for the OCI archive name in `vm/`.

**Use the smoke tests.** The ham stack and the codec swap are the two things a
Fedora version bump will break. A targeted build fails in a couple of minutes;
bisecting the full image takes twenty.

Inspect what you built without booting it:

```bash
podman run --rm localhost/kb3lyb-shack:44 bash -c 'rpm -qa | grep -Ei "wsjt|fldigi|hamlib" | sort'
podman run --rm localhost/kb3lyb-shack:44 /usr/lib/opt/sdrtrunk/bin/sdr-trunk --help
```

---

## 3. VM testing

```bash
bash vm/export-image.sh        # rootless: image -> vm/kb3lyb-shack.oci
sudo bash vm/build-qcow2.sh    # rootful:  .oci  -> vm/output/qcow2/disk.qcow2
bash vm/boot-check.sh          # headless boot, screenshots the greeter
```

`build-qcow2.sh` and `build-iso.sh` need root because bootc-image-builder refuses
rootless (loop devices, SELinux labeling). Booting afterwards does not.

The VM is where you check that greetd comes up and niri renders. It **cannot**
check anything needing real hardware — no GPU means no `vainfo`, no USB means no
radios.

---

## 4. Build the installer ISO

```bash
bash vm/export-image.sh
sudo bash vm/build-iso.sh
```

> [!CAUTION]
> `--type anaconda-iso` is **unattended by default**: with no kickstart it
> installs to the first disk it finds, no prompt, no encryption. `vm/build-iso.sh`
> forces an interactive install by passing `vm/iso-config.toml` (an empty
> `[customizations.installer.kickstart]`). **Never build this ISO without it.**
> Confirm the target disk by serial and size before proceeding — this machine has
> exactly one disk and it currently holds Windows.

---

## 5. Installing

The machine has **one** 256 GB NVMe (`WD PC SN740`), currently holding a licensed
Windows 10 IoT Enterprise LTSC install. Installing destroys it.

Before wiping, work through §7.

If you are adding a 2.5" SSD for data (recommended — see DESIGN §7), **fit it
before installing**, so the installer can lay out both drives in one pass.

---

## 6. First boot — the per-machine steps the image cannot do

The image ships defaults; these depend on the operator or the hardware and must be
done once on the machine.

### 6.1 Groups — do this first, nothing radio works without it

```bash
sudo usermod -aG dialout,rtlsdr,audio,kismet "$USER"
# log out and back in; then confirm:
id
```

- `dialout` — every USB serial CAT/programming cable
- `rtlsdr` — the group `rtl-sdr`'s udev rules assign to SDR dongles
- `audio` — direwolf's hidraw PTT path (CM108-style interfaces)

### 6.2 Verify hardware VA-API (cannot be checked at build time)

```bash
vainfo | head
# expect: Driver version: Intel iHD driver ...
```

If this says something else, re-read `recipes/common/codecs.yml` — the free/nonfree
split is the usual cause.

### 6.3 Fix the display layout

The connector names in `/etc/niri/config.kdl` are **placeholders**.

```bash
niri msg outputs      # real connector names + modes
```

Correct the `output` blocks, and the `position x=` of the second head to match the
first head's actual width. Then `niri msg action reload-config`.

### 6.4 Verify the floating window rules actually fire

A window rule that matches nothing is **completely silent** — niri emits no
warning for an unmatched rule (checked: its binary carries no such diagnostic).
The rule is simply inert, WSJT-X opens tiled with a squeezed waterfall, and
nothing anywhere says why. This is the single most likely thing in this image to
be quietly wrong, because the patterns were written from informed guesses:
`app-id` (Wayland) and `WM_CLASS` (X11) cannot be read off a package.

Open WSJT-X, fldigi, CHIRP, sdrtrunk and a Wine app, then:

```bash
kb3lyb-check-window-rules
```

It lists every live `app-id`, marks each rule `ok` or `UNMATCHED`, names any
window no rule claims, and exits nonzero if anything matched nothing. `niri msg
windows` gives the same raw data if you prefer to read it yourself.

The two patterns most likely to be wrong:

- **`^(?i)wine$`** — the one that matters for the RT Systems programmers. Wine
  sets `WM_CLASS` to two fields, e.g. `("radioengine_v5.exe", "Wine")`, and
  whether niri's `app-id` maps to the instance name or the class name decides
  whether this ever fires. If it maps to the instance, every RT Systems window
  tiles.
- **`^(?i).*sdrtrunk.*$`** — Java/Swing often reports its main class name rather
  than the `StartupWMClass` set in the `.desktop` file that
  `files/scripts/install-sdrtrunk.sh` writes. If this rule misses, check that
  file before touching the rule.

Fix any pattern that missed, then `niri msg action reload-config`.

### 6.5 Radios

```bash
ls -l /dev/serial/by-id/     # stable names — use these, not /dev/ttyUSB0
rigctl -m <model> -r /dev/serial/by-id/<cable> -vvv f
rtl_test -t                  # SDR dongle
```

All four cable types on this desk are supported in-tree — including the RT Systems
USB-29F (`2100:9E55`, claimed by `ftdi_sio`). No udev rule needed. See DESIGN §1.

For a rig shared between apps, run one `rigctld` and point everything at it rather
than letting six programs fight over the port. To fan a port out to two apps that
insist on owning one, use `socat`:

```bash
socat -d -d pty,raw,echo=0 pty,raw,echo=0     # the com0com replacement
```

### 6.6 Dotfiles + the $HOME-scoped installers

```bash
/usr/bin/kb3lyb-bootstrap        # brew, SDKMAN, stow-deployed configs
pipx install not1mm              # contest logger (DESIGN §5)
```

GridTracker2 is also a `$HOME` install — it is used daily on the Windows box and
is *not* in this image by design.

### 6.7 Restore the logs

Backed up to `~/src/kb3lyb-backup-20260825/`:

| From | To | Notes |
|---|---|---|
| `log4om/Log4OM_ADIF_20260826005047.adi` | import into **QLog** | 5,804 QSOs — the authoritative log |
| `wsjtx/wsjtx_log.digital.adi` | rename to `wsjtx_log.adi` in `~/.local/share/WSJT-X/` | digital-only; **do not import into QLog** — see below |
| `wsjtx/wsjtx_log.adi` | keep as the untouched original | superseded by the digital-only file |
| `wsjtx/WSJT-X.ini`, `ALL.TXT` | `~/.local/share/WSJT-X/` | |
| `kb3lyb-shack-backup.tar.gz` | unpack as needed | Log4OM SQLite, N1MM, HRD, GridTracker, JTAlert, RT Systems |
| `kb3lyb-winlink.tar.gz` | reference only | Winlink Express is Windows; Pat replaces it |

CHIRP `.img` files already sync via Nextcloud.

#### IMPORT THE LOG4OM ADIF ONLY. Do not also import wsjtx_log.adi.

Analysed 2026-08-25, before anyone had a chance to merge them by hand:

- The Log4OM export is **already deduplicated** — zero same call+band+date repeats.
  Its only five near-duplicates are rovers (`K8RYU/R`, `K3ARL/R`) worked twice on
  different frequencies hours apart. Real QSOs. Do not "clean" them.
- `wsjtx_log.adi` holds 8,584 records with **2,745 same call+band+date repeats** —
  FT8 retry spam. `A71UN` on 17m appears **30 times in one day**; Log4OM kept one.
- Exactly **2** FT8 QSOs exist in the WSJT-X file and not in Log4OM. Neither is
  confirmed.
- That file also contains 1,186 SSB QSOs, which WSJT-X cannot make — so it is not
  a pure WSJT-X log; something merged the full log back into it, which is also why
  it carries LoTW/eQSL flags.

Importing both would inject ~2,780 duplicates that Log4OM already rejected, in
pairs where one side carries confirmations and the other does not — the exact
situation in which a careless dedup destroys LoTW/eQSL status. The safe move is
not to create it.

`wsjtx_log.adi` still belongs on the machine: WSJT-X and JTAlert read it purely to
colour-code previously-worked callsigns. It is a display cache, not a log of
record. Copy it into place and otherwise ignore it.

#### Use the digital-only variant

`wsjtx_log.digital.adi` is that file with the 1,321 non-digital records removed
(1,186 SSB, 113 CW, and a few RTTY/FM/PSK/AM/SSTV), leaving 7,263 FT8 + MFSK.
FT8 count is preserved exactly: 6,394 in, 6,394 out.

The point is what it changes on screen. **921 callsigns had only ever been worked
on SSB or CW.** With those records in the file, WSJT-X paints those stations as
"worked before" and you skip a call you have never actually worked on a digital
mode. Removing them costs the "already have it" hint for just **4 DXCC entities
and 30 grids** — a lopsided trade.

Whether it matters at all depends on WSJT-X's *Settings → Colors* rules on this
machine, which decide if the worked-before test considers mode. That cannot be
read reliably out of `WSJT-X.ini` (it is a serialised Qt variant blob), so check
it in the UI. If the test ignores mode, the digital-only file is the one you want.

It was produced by slicing records out of the source text between `<eor>` markers
rather than by parsing and re-emitting fields — a re-serialising filter would
silently drop any field the parser mishandled. The original is kept unmodified
alongside it.

---

## 7. Backup checklist — BEFORE wiping

Already captured:

- [x] Log4OM ADIF export (5,804 QSOs)
- [x] WSJT-X `wsjtx_log.adi`, `ALL.TXT`, `WSJT-X.ini`, WSPR history
- [x] `fldigi.files/`, `NBEMS.files/`
- [x] RT Systems `DRCS25.dat`, `KGUV96.dat`
- [x] Full installed-software inventory
- [x] CHIRP `.img` files (already in Nextcloud)

Still to capture:

- [ ] Log4OM SQLite DBs — `%APPDATA%\Log4OM2\*.SQLite` (`Activations` is ~153 MB)
- [ ] N1MM Logger+ database — `Documents\N1MM Logger+\`
- [ ] Ham Radio Deluxe logbook — `%APPDATA%\HRDLLC\`
- [ ] JTAlert + GridTracker2 settings (skip the `Cache/`/`GPUCache/` dirs)
- [ ] Winlink Express — `C:\RMS Express\`
- [ ] Win4Yaesu / Win4Icom Suite profiles — `Documents\Win4*Suite\`
- [ ] **The Windows licence/recovery position**, if you ever want IoT LTSC back
- [ ] `.ssh/`, Tailscale state, anything under `Documents\DXLab`

---

## 8. Updates & rollback

- `rpm-ostreed-automatic.timer` **stages** updates; they apply on next boot.
- `flatpak-update.timer` (system) and `flatpak-update-user.timer` (user) keep
  Flatpaks current — the user one must stay a *user* unit, since polkit only
  guards the system installation.
- `kb3lyb-image-age.timer` warns when the image stops moving. A nightly that has
  been red for a month otherwise looks exactly like one that has been green.

```bash
rpm-ostree status              # what is deployed / staged
rpm-ostree rollback            # previous deployment
systemctl reboot
```

Timestamped tags are published alongside `latest` for pinning.

---

## 9. Open follow-ups

Tracked in DESIGN §6. The two worth doing first, because both can *delete* work:

1. **Try CHIRP on the DR-CS25 and KG-UV96.** If it handles them, the entire Wine
   dependency and 195 i686 packages come out of the recipe.
2. **Try the RT Systems programmers under plain new-WoW64** (drop
   `wine-core.i686`, rebuild, test). If they work, drop the line permanently.
