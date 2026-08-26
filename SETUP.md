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

### 6.0 Re-point the machine at the registry. DO THIS FIRST.

**An install from the ISO cannot update itself until you do.** The installer's
kickstart ends with:

```
bootc switch --mutate-in-place --transport registry localhost/kb3lyb-shack:44
```

so the freshly installed system's origin is **`localhost/kb3lyb-shack:44`** — a
ref that exists in no registry. `rpm-ostree upgrade` and
`rpm-ostreed-automatic.timer` will therefore fail on every attempt, and the
machine sits on the ISO's image forever. Nothing about the desktop looks wrong;
it just silently stops receiving updates. (`kb3lyb-image-age.timer` is the
backstop that eventually complains — but it should never get the chance.)

Two steps, because the first is what installs the signing policy that lets the
second be verified:

```bash
# 1. unsigned first — this pulls in the cosign key + policy
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/mark-iid/kb3lyb-shack:latest
systemctl reboot

# 2. then the signed image, which is what you actually want to run
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mark-iid/kb3lyb-shack:latest
systemctl reboot
```

Confirm it took:

```bash
rpm-ostree status        # origin must name ghcr.io, NOT localhost
```

This step is only needed for an ISO install. A machine rebased from an existing
Fedora Atomic install already points at the registry.

### 6.0b `systemd-remount-fs.service` fails on every boot. Ignore it.

`systemctl --failed` will always show:

```
● systemd-remount-fs.service  ... Remount Root and Kernel File Systems
  mount: /: fsconfig() failed: overlay: No changes allowed in reconfigure.
```

This is cosmetic and expected on bootc. `/` is a **composefs overlay**, already
read-only by design, and overlayfs does not support reconfigure — so the unit's
attempt to apply fstab's `ro` option to `/` cannot succeed and never could.
Nothing is wrong: `/boot`, `/var` and `/home` all mount normally and `/var` and
`/home` are writable.

It is recorded here because a permanently-failed unit is exactly the kind of
thing that looks like the cause when some unrelated problem turns up months
later. It is not.

### 6.0c Adding a karg to the image does NOT apply it to a running machine

`/usr/lib/bootc/kargs.d/` is applied when a deployment **transitions** — a rebase,
or the initial install. It is **not** re-evaluated on every `rpm-ostree upgrade`.
So a karg added to the image after this machine was already on that image lineage
silently never takes effect: the file is present in `/usr/lib/bootc/kargs.d/`, the
build asserts it, and `/proc/cmdline` does not have it.

This is not theoretical. `consoleblank=1200` was added, the image shipped it, the
upgrade installed it, and the running kernel never saw it. Worse, the same thing
had already happened on the **laptop** image without anyone noticing:

```
kargs.d says: amdgpu.dcdebugmask=0x10, plymouth.enable=0, loglevel=3
cmdline has:  amdgpu.dcdebugmask=0x10        <- applied at the original rebase
              (quiet and rhgb still present) <- the other two never applied
```

Two of that machine's three kargs have been inert for its entire life.

**So: after adding a karg to the image, apply it on each running machine too.**

```bash
sudo rpm-ostree kargs --append-if-missing=<karg>
systemctl reboot
tr ' ' '\n' < /proc/cmdline | grep <karg>    # verify — do not assume
```

`--append-if-missing` is idempotent, so it is safe even if a future rebase does
apply the kargs.d entry.

### 6.1 Groups — do this first, nothing radio works without it

> [!WARNING]
> **`usermod -aG dialout` SILENTLY DOES NOTHING on this OS.** It exits 0, prints
> no error, and the membership is never created. Verified on the first real boot,
> 2026-08-26.
>
> The cause is ostree's split account database. `/etc/group` holds only groups
> created *locally*; the base system groups live in the read-only
> `/usr/lib/group`. `usermod` resolves `dialout` through NSS, finds it, believes
> it succeeded, and writes nothing that persists. `rtlsdr` works — it was created
> locally by systemd-sysusers, so it has a real `/etc/group` entry — which makes
> the failure look even more like success, since one of the three groups does get
> added.
>
> Without `dialout` no serial port opens, so every radio on the desk is dead and
> nothing says why.

Seed the missing groups into `/etc/group` first, then add yourself:

```bash
for g in dialout audio; do
  grep -q "^$g:" /etc/group || grep "^$g:" /usr/lib/group | sudo tee -a /etc/group >/dev/null
  sudo usermod -aG "$g" "$USER"
done
sudo usermod -aG rtlsdr "$USER"     # already local; plain usermod is fine
```

**Verify — do not assume:**

```bash
id -nG            # must list dialout, audio, rtlsdr
grep -E '^(dialout|audio|rtlsdr):' /etc/group   # each line must end with your username
```

Then log out and back in for the session to pick them up.

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

### 6.6b Mount Nextcloud (do not sync it)

The Windows install this replaces already used online-only placeholders: the tree
reports ~88 GB but almost none of it was on disk (Windows showed 60 GB used of
238 GB total). Cloning it here would be 88 GB against a 238 GB drive that also
holds two rpm-ostree deployments. So: mount.

Two ways, both already in the image.

**rclone** — gives a real FUSE path immediately, works for every app:

```bash
rclone config          # new remote, type: webdav
                       # url: https://<your-nextcloud>/remote.php/dav/files/<user>/
                       # use a Nextcloud app password, not your account password
mkdir -p ~/Nextcloud
rclone mount nc: ~/Nextcloud --vfs-cache-mode writes --daemon
```

Make it persistent with a user unit in dotfiles (the credentials belong there,
not in this image).

**GVFS** — `davs://` in Thunar, no config needed. WebDAV is built into the base
`gvfs` (`gvfsd-dav`), so this works out of the box.

> [!IMPORTANT]
> GVFS alone is not enough for the ham apps. Without **`gvfs-fuse`** a GVFS mount
> lives only inside GIO's URI namespace — Thunar sees it, and nothing else does.
> WSJT-X is Qt, fldigi is FLTK, CHIRP is wxPython, sdrtrunk is Java; none of them
> would find a file on it, and the symptom is an empty file picker rather than an
> error naming the cause. `gvfs-fuse` projects the mount into
> `/run/user/$UID/gvfs/...` as a real path. It is in the recipe for this reason —
> do not drop it as redundant with `gvfs`.

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
- [ ] **Revoke the temporary inventory SSH key.** A throwaway ed25519 key
      (comment `claude-shack-inventory`) was added to
      `C:\ProgramData\ssh\administrators_authorized_keys` on 2026-08-25 to take
      this backup. It dies with the wipe, so this is only outstanding while the
      Windows install still exists. To remove it early:
      ```powershell
      $f='C:\ProgramData\ssh\administrators_authorized_keys'
      (Get-Content $f) | Where-Object { $_ -notmatch 'claude-shack-inventory' } | Set-Content $f
      ```
- [ ] Consider whether the Windows 10 IoT Enterprise LTSC licence/recovery is
      worth preserving — a plain reinstall will not reproduce it

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

## 9. Where this stands, and what is still open

Current as of 2026-08-26. This section is the handoff: read it first if you are
picking the project up on the shack machine.

### Done

- Image builds, signs, and publishes. `ghcr.io/mark-iid/kb3lyb-shack:latest`.
- Installed on the EliteDesk from an interactive Anaconda ISO.
- Rebased off the installer's `localhost/` origin onto the registry (§6.0).
- All six USB serial cables enumerate with in-tree drivers — the RT Systems
  CT29F on `ftdi_sio`, two FT232Rs, both CP2105 interfaces on `cp210x`, a CH340
  on `ch341-uart`. No udev rules needed.
- Groups fixed (§6.1 — and read that warning, it is not the obvious command).
- Logs backed up off the Windows install: 5,804-QSO Log4OM ADIF, WSJT-X data,
  fldigi/NBEMS, RT Systems `.dat` files, Log4OM SQLite, N1MM, HRD, Winlink.

### Answered, so nobody re-investigates them

- **CHIRP cannot replace the RT Systems programmers.** Checked against the
  installed CHIRP 0.4.0 and its 528 models: the Alinco **DR-CS25** and Wouxun
  **KG-UV96** are both absent. Model names confirmed from the programmers' own
  DLL version resources. Wine is load-bearing, not optional.
- **`wine-core.i686` was dropped and that is fine.** Fedora 44's
  `wine-core.x86_64` ships new-WoW64, so 32-bit Windows binaries still run. The
  i686 package only added the classic `i386-unix` loader, at a cost of 186
  packages / 1.23 GB. If an RT Systems programmer fails, adding that one line
  back is the fix — try that before anything else.
- **The logs need no deduplication.** See §6.7. Do not "tidy" them.

### Genuinely open

1. **Do the RT Systems programmers actually work under Wine?** Untested. The
   cable side is proven; the app side is not. They are native Win32/MFC
   (`RadioEngine_V5.exe` + per-radio DLL, linked against `mfc100u`), which is a
   far better Wine prospect than .NET. The risk is serial control-line handling
   (DTR/RTS) on a cloning cable, not the GUI.
2. **N1MM under Wine is expected to fail** (.NET over SQL Server Compact). If real
   N1MM is needed, use a Windows VM — install `org.gnome.Boxes` then, it is
   deliberately not baked. `not1mm` is the Linux alternative: `pipx install not1mm`.
3. **niri window rules are unverified.** Run `kb3lyb-check-window-rules` with the
   ham apps open. The `wine` and `sdrtrunk` patterns are the doubtful ones (§6.4).
4. **Display connector names in `/etc/niri/config.kdl` are placeholders.** Fix
   from `niri msg outputs` (§6.3).
5. **GridTracker2** is used daily on Windows and is packaged nowhere. It is a
   `$HOME` install, deliberately not baked.
6. **Passwordless sudo** may still be enabled at `/etc/sudoers.d/99-nopasswd`
   from the remote-setup session. Remove it if you do not want it:
   `sudo rm /etc/sudoers.d/99-nopasswd`.

### Working on this repo from the shack machine

```bash
git clone https://github.com/mark-iid/hamshack.git ~/src/kb3lyb
cd ~/src/kb3lyb
./build-local.sh recipes/ham-test.yml     # fast: ham stack only
./build-local.sh                          # full image (~10 min, 13.6 GB)
```

Pushing needs auth — either `gh auth login` (gh comes from brew, not the image)
or an SSH key added to GitHub. The build is **rootless**; only `vm/build-iso.sh`
and `vm/write-usb.sh` need sudo, and building with sudo puts the image in root's
podman store where `vm/export-image.sh` cannot find it.

The signing key is **not** in the repo (correctly — it is gitignored). It lives at
`~/Nextcloud/Documents/keys/kb3lyb-shack-cosign.key`, which is reachable once
Nextcloud is mounted (§6.6b). Do not lose it; the equivalent key for the laptop
image already was.
