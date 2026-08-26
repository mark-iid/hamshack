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

A window rule that matches nothing is **silent** — this is how the config rots.

```bash
niri msg windows      # app-id + title for every open window
```

Open WSJT-X, fldigi, CHIRP, sdrtrunk and a Wine app; check each opened floating.
Fix any `app-id` pattern that did not match.

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

Backed up to `~/src/kb3lyb-backup-20260825/` (and in Nextcloud):

- `log4om/Log4OM_ADIF_20260826005047.adi` — 5,804 QSOs → import into **QLog**
- `wsjtx/` → `~/.local/share/WSJT-X/`
- `fldigi/fldigi.files`, `fldigi/NBEMS.files` → `~/`
- `rtsystems/` → the two `.dat` files, if Wine works out

CHIRP `.img` files already sync via Nextcloud.

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
