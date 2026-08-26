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

### 6.3 Display layout — done; re-check only after a cable or monitor change

No longer placeholders. This machine has **HDMI-A-1** (Lenovo T2224pD, 1920x1080)
and **DP-3** (ViewSonic VA2037, 1600x900); the other four DP/HDMI connectors the
i915 exposes are disconnected. HDMI-A-1 is the primary and sits at the origin,
DP-3 is to its **left** at `x=-1600`, both top-aligned at `y=0`.

```bash
niri msg outputs      # connector names, modes, and logical positions
```

A left-hand monitor's `x` is minus **its own** width — that is what lands its
right edge on the primary's left edge at 0. It is not minus the primary's width.
Redo that arithmetic if either panel is replaced. niri reloads on save; `niri msg
action reload-config` forces it.

**Watch which file you are editing.** niri prefers `~/.config/niri/config.kdl`,
and here that is a stow symlink into the `dotfiles` repo shared with the Framework
laptop — so the image's `/etc/niri/config.kdl` is **inert on this machine**. Change
both, or you will fix a display problem in a file nothing reads. One config can
serve both machines because niri silently ignores an `output` block whose connector
is absent; that same silence is why a typo'd connector name reports nothing at all.

The greeter is a third, separate config: `/etc/niri/greeter.kdl` pins the login
screen to HDMI-A-1 and switches DP-3 `off`, so it is unaffected by the arrangement
above — but if HDMI-A-1 is ever unplugged, read the failure mode recorded in it.

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

> [!CAUTION]
> **Opening the FT-710's CAT port KEYS THE TRANSMITTER.** Not the command — the
> *open*. A serial open asserts DTR and RTS by default, and on this rig that line
> is PTT. A plain `rigctl ... f`, which only reads frequency, put the radio into
> transmit on 2026-08-26. Probing several baud rates made it worse: every attempt
> that got no reply still opened the port and held PTT until it timed out.
>
> So never probe this rig's port bare. Always disable the control lines first:
>
> ```bash
> rigctl -m 1049 -r /dev/serial/by-id/<cable> \
>        --set-conf=dtr_state=OFF,rts_state=OFF -s 38400 f
> ```
>
> And prefer *asking which port is CAT* over discovering it by sweeping — a sweep
> is a series of unintended transmissions into whatever load is connected.

Verified on this machine 2026-08-26:

| | |
|---|---|
| Rig | Yaesu **FT-710** (`MY_RIG=FT710` on 5,752 logged QSOs) |
| Hamlib model | **1049** |
| CAT port | CP2105 **`if00`** — `usb-Silicon_Labs_CP2105_..._01B687FB-if00-port0` |
| Baud | **38400** (19200 and 115200 got no reply) |

`if01` is the CP2105's second interface and answered on no rate tested; on this
rig family that port is the PTT/audio side, not CAT.

**WinKeyer: `usb-FTDI_FT232R_USB_UART_AH071WD4-if00-port0`, 1200 baud.** Identified
2026-08-26 by sending the WinKeyer Host Open command (`00 02`) and reading the
version byte back: `0x1F` = 31, i.e. WinKeyer 3 firmware v3.1.

This needs probing to establish because **both FT232Rs present identical USB
descriptors** — `FTDI FT232R USB UART`, `0403:6001` — so only the serial number
distinguishes them. The other one (`FTWOSJ47`) and the CH340 (`1a86:7523`) both
stayed silent, so neither speaks the WinKeyer protocol; they remain unidentified.

Do not conclude anything from `<WK_K3NGsketch>` in a backed-up `fldigi_def.xml`.
That line reads "Mortty loaded with K3NG WinKeyer emulator sketch", which looks
like a statement about this station but is fldigi's stock description of the
option — the value here is 0.

To re-probe safely, drop DTR/RTS on open: on a bare keying interface those lines
are key and PTT. `scratchpad`-style throwaway is fine; the sequence is host-open
`00 02`, read one byte, then host-close `00 03`.

```bash
ls -l /dev/serial/by-id/     # stable names — use these, not /dev/ttyUSB0
rtl_test -t                  # SDR dongle
```

All four cable types on this desk are supported in-tree — including the RT Systems
USB-29F (`2100:9E55`, claimed by `ftdi_sio`). No udev rule needed. See DESIGN §1.

#### One rigctld, bound to the radio — and every app points at it

This is set up: `rigctld.service` (user unit, in the dotfiles `systemd/` package).
One daemon owns the serial port; nothing else opens it. Two apps opening the same
tty means whichever starts second simply fails.

It is **bound to the rig's device unit**, not started at login. The FT-710's CAT
interface is a CP2105 powered by the radio, so it enumerates only while the rig is
switched on — `BindsTo=`/`WantedBy=` that device unit means rigctld starts when the
radio comes on and stops when it goes off. No timer, no restart loop against
hardware that is not there.

```bash
systemctl --user enable rigctld.service    # start whenever the rig appears
systemctl --user status rigctld.service
rigctl -m 2 -r 127.0.0.1:4532 f            # confirm from a second process
```

Point every client at **Hamlib NET rigctl — model 2 — `127.0.0.1:4532`**:

| App | Setting |
|---|---|
| QLog | Rig model *Hamlib NET rigctl*, hostname `127.0.0.1`, port `4532` |
| WSJT-X | Radio → Rig *Hamlib NET rigctl*, Network Server `127.0.0.1:4532` |
| Pat | hamlib rig with address `127.0.0.1:4532`, network `tcp` |
| fldigi | Rig control → Hamlib, NET rigctl at the same address |

Do **not** also give these apps the raw `/dev/serial/by-id/...` path. That is the
configuration mistake this whole arrangement exists to prevent.

> [!IMPORTANT]
> **Use `127.0.0.1`, never `localhost`.** The unit binds `-T 127.0.0.1`, IPv4 only,
> and `localhost` resolves to `::1` first on this machine — so a client configured
> with `localhost` gets connection-refused. QLog surfaces that as a downstream
> *"Get Mode Error / Protocol error"* rather than a connect failure, which sends you
> looking in entirely the wrong place. Confirmed 2026-08-26.

**The FT-710's CAT processor is shared, and it saturates.** CATTouch is a second
CAT consumer on this rig, and the '710 starves under the combined load — the
symptom is intermittent hamlib protocol errors in whichever client loses the race,
not a clean failure. So keep the software side's CAT traffic modest: QLog shipped
defaults of a 500 ms poll asking for frequency, mode, VFO, RF power, split *and* CW
key speed. The poll interval is now **1000 ms** (halved from QLog's 500 ms default)
with **all reads enabled** — the operator wants the full rig readout and accepts the
CAT load. If intermittent protocol errors return, that is the CAT budget being
exceeded rather than a broken command, and the lever is this list: drop
`get_key_speed` and `get_pwr` first (cosmetic), then `get_split`/`get_vfo`, then
widen the interval to 2000 ms. Do not go back to 500 ms.

The unit carries `--set-conf=dtr_state=OFF,rts_state=OFF`. Per the CAUTION above
that is a safety setting, not tuning — and rigctld holds the port open the entire
time it runs. It also binds `-T 127.0.0.1`: rigctld has no authentication of any
kind, so anything that can reach the port can key the transmitter.

To fan a port out to two apps that insist on owning one, use `socat`:

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
rclone config          # new remote, name it `nextcloud`, type: webdav
                       # vendor: nextcloud
                       # use a Nextcloud app password, not your account password
```

> [!IMPORTANT]
> **The URL must end in `/remote.php/dav/files/<user>/`.** A bare host is the easy
> mistake and it does not work — rclone refuses with *"the remote url looks
> incorrect"*. For this machine it is
> `https://nas1.mystikos.org/remote.php/dav/files/mark/`.
> Note `rclone config` is a full interactive prompt loop and needs a real TTY, so
> run it in a terminal window; it cannot be driven from a non-interactive shell.
> Only the URL is worth recording here — the app password lives in
> `~/.config/rclone/rclone.conf` and belongs in no repo.

Persistence is `rclone-nextcloud.service` in the dotfiles `systemd/` package
(credentials belong there, not in this image):

```bash
systemctl --user enable --now rclone-nextcloud.service
mountpoint ~/Nextcloud        # must say "is a mountpoint", not just list files
```

The niri config spawns that unit on the shack machine and, on the laptop only,
the Nextcloud **desktop sync client** — the two are mutually exclusive by
hostname guard, because a sync client pointed at `~/Nextcloud` would try to pull
the whole ~88 GB tree onto a 238 GB disk. Do not remove that guard.

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

### 6.8 32-bit Wine needs an SELinux module on this image

**Symptom.** Every 32-bit Windows binary fails instantly under Wine. 64-bit ones
are fine, which makes it look like a Wine capability problem. It is not.

```bash
wine /usr/lib64/wine-wow64/wine/i386-windows/cmd.exe /c ver   # the 60-second check
```

That should print a Windows version. If it exits non-zero, this module is missing.

**Cause.** `avc: denied { execmod } ... tcontext=...:lib_t tclass=file`. 32-bit PE
DLLs need text relocations, so Wine maps `.text` write-then-execute — the
`execmod` permission. The confusing part is *who* is denied: Wine runs as
`unconfined_t` and `selinuxuser_execmod` is already on, yet the denial names
`kernel_t`. That is because `/` is **composefs**, an overlay whose data lives in
the ostree object store, and overlayfs checks the backing file with the
**mounter's** credentials — and the bootc root is mounted by `kernel_t`. So this
is a property of the image's root filesystem, not of Wine. It does not happen on
ordinary Fedora, which is exactly why it is surprising here.

**Fix.** Source and rationale are in `selinux/kb3lyb-wine32.te` in this repo:

```bash
checkmodule -M -m -o /tmp/kb3lyb-wine32.mod selinux/kb3lyb-wine32.te
semodule_package -o /tmp/kb3lyb-wine32.pp -m /tmp/kb3lyb-wine32.mod
sudo semodule -i /tmp/kb3lyb-wine32.pp
sudo semodule -l | grep kb3lyb        # verify
```

### 6.8b `wine` is NOT the 32-bit entry point — `wine32` is

With `wine-core.i686` in the image (recipe change 2026-08-26), a genuine 32-bit
prefix is possible — but **only via `/usr/bin/wine32`**:

```bash
export WINEARCH=win32 WINEPREFIX=~/.local/share/wineprefixes/rt32
/usr/bin/wine32 wineboot -u        # works -> #arch=win32
wine wineboot -u                   # FAILS: "not supported in wow64 mode"
```

`/usr/bin/wine` is a symlink to `/etc/alternatives/wine`, which resolves to
**`wine64`** — and `alternatives --display wine` prints nothing, i.e. the i686
package's alternative was never configured. The build log says so out loud
(`/usr/bin/wine32 has not been configured as an alternative for wine`) and it is
easy to read past. So plain `wine` refuses win32 prefixes no matter what is
installed, and the failure message blames wow64 mode rather than the symlink.

Use `wine32` for everything touching a win32 prefix, including winetricks:

```bash
WINE=/usr/bin/wine32 WINESERVER=/usr/bin/wineserver32 \
  WINEARCH=win32 WINEPREFIX=~/.local/share/wineprefixes/rt32 \
  winetricks -q vcrun2010
```

Verified after the reboot onto the new image: `#arch=win32` prefix created, and
32-bit `cmd.exe` runs under SELinux **Enforcing**. The `kb3lyb-wine32` policy
module survives a reboot (it lives in `/etc/selinux`, not in the image).

### 6.8c RT Systems programmers: where this actually got to

**Not working. Two prefixes, two different failures, neither installs.**

| prefix | result |
|---|---|
| `~/.local/share/wineprefixes/rtsystems` (win64/WoW64) | reaches language -> serial -> email -> install path, then dies in `err:seh:call_seh_handlers invalid frame` |
| `~/.local/share/wineprefixes/rt32` (win32) | language dialog -> OK -> spawns four processes -> all exit cleanly, rc=0, **zero errors**, nothing installed |

Both prefixes have `vcrun2010` (the programmers link against `mfc100u`/`msvcr100`).

The win32 result is the informative one: no crash, no exception, no missing DLL —
just routine `fixme` lines and a clean exit. That is an installer *choosing* to
stop on some prerequisite check, not Wine failing. Candidates are a cable-presence
check, an elevation check, or an OS-version check, and there is no error to
distinguish them. Note it went **backwards**: the win32 prefix, which was supposed
to be the fix, does not even reach the serial prompt.

Things already ruled out, so nobody repeats them:

- Not the SELinux denial (§6.8) — fixed, and 32-bit runs fine now.
- Not a missing MFC runtime — `winetricks -q vcrun2010` installed it in both.
- Not the registration key: porting the `Software\RT Systems V5\...` key from the
  win64 prefix into the win32 one, and removing it again, changed nothing.
- Not the GUI/toolkit — the MFC dialogs render and respond correctly.

**Recommendation: stop tuning Wine here.** This is the case §9 and the recipe
comment both describe — the honest answer is a small Windows VM with USB
passthrough (`org.gnome.Boxes`, deliberately not baked). An untried data point that
costs little: run `KGUV96_Setup.exe` and see whether it fails the same way, which
would say whether this is DRCS25-specific or common to RT Systems' installers.

> [!NOTE]
> This is **machine-local state the image does not describe** — a fresh install
> will not have it, and this section is the only record of that. It grants
> `execmod` on all of `lib_t`, which is broader than wanted. The narrow fix is to
> relabel only Wine's `i386-windows` files, but `/usr` is read-only composefs, so
> that cannot be done at runtime and has to happen at image build. Bake it once
> the programmers are known to work; there is no point hardening a path that may
> yet be abandoned for a Windows VM.

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
- Displays done and verified on the hardware (§6.3): HDMI-A-1 (1920x1080) primary
  at the origin, DP-3 (1600x900) to its left at `x=-1600`. Note that the config
  niri actually reads here is the stowed dotfiles copy, not the image's
  `/etc/niri/config.kdl`; the greeter stays pinned to HDMI-A-1 either way.
- Nextcloud mounted (§6.6b) as an rclone WebDAV FUSE mount at `~/Nextcloud`,
  via `rclone-nextcloud.service`, enabled at login. The signing key is reachable
  again and its public half matches the repo's `cosign.pub`.
- Logs backed up off the Windows install: 5,804-QSO Log4OM ADIF, WSJT-X data,
  fldigi/NBEMS, RT Systems `.dat` files, Log4OM SQLite, N1MM, HRD, Winlink.

### Answered, so nobody re-investigates them

- **CHIRP cannot replace the RT Systems programmers.** Checked against the
  installed CHIRP 0.4.0 and its 528 models: the Alinco **DR-CS25** and Wouxun
  **KG-UV96** are both absent. Model names confirmed from the programmers' own
  DLL version resources. Wine is load-bearing, not optional.
- **`wine-core.i686` was dropped. There are TWO separate 32-bit problems, and
  this package is the answer to exactly one of them.** Read both before acting.
  The packaging facts are confirmed: `wine-core.x86_64` ships new-WoW64 (819
  `i386-windows` PE files, zero `i386-unix`); the i686 package adds only the
  classic `i386-unix` loader, at 186 packages / 1.23 GB. What was never confirmed
  was the conclusion "so 32-bit Windows binaries still run" — that came from
  `rpm -ql`, not from running anything.
  1. **SELinux `execmod` (§6.8).** Blocks *every* 32-bit PE. `wine-core.i686`
     does NOT fix this — the denial is on the PE files' label, not the loader.
     Fixed by the policy module instead.
  2. **new-WoW64 SEH failure.** With §6.8 in place the DRCS25 installer runs, draws
     its MFC GUI, accepts a serial and an install path, then dies in
     `err:seh:call_seh_handlers invalid frame` with addresses above 4 GB inside a
     32-bit process. `wine-core.i686` IS the lever here: without it,
     `WINEARCH=win32` is refused outright (*"not supported in wow64 mode"*), so a
     pure 32-bit prefix — which sidesteps the WoW64 exception path entirely —
     cannot be created at all.
  So the old advice to "try adding that line back first" was wrong for problem 1
  and right for problem 2. Do §6.8 first; reach for i686 only against the SEH
  crash, and expect the 1.23 GB.
- **The logs need no deduplication.** See §6.7. Do not "tidy" them.
- **The Nextcloud mount stays enabled at login — deliberate.**
  `rclone-nextcloud.service` is `enabled`, so `~/Nextcloud` is mounted whenever the
  machine is up and networked. That means the cosign signing key at
  `~/Nextcloud/Documents/keys/` is reachable at a fixed path all the time, not only
  when deliberately mounted. The operator weighed that and chose convenience —
  building and signing needs the key routinely. Do not switch this to manual start
  as a "hardening" tidy-up.
- **Passwordless sudo is deliberate — leave it.** `/etc/sudoers.d/99-nopasswd`
  survives from the remote-setup session and is confirmed still active. The
  operator has chosen to keep it. Do not "harden" this away.

### Genuinely open

1. **Do the RT Systems programmers actually work under Wine?** Still untested,
   but no longer for want of software — `DRCS25_Setup.exe` and `KGUV96_Setup.exe`
   are downloaded to `~/Downloads`. They are native Win32/MFC (`RadioEngine_V5.exe`
   + per-radio DLL, linked against `mfc100u`), a far better Wine prospect than
   .NET, and the cable side is already proven.
   **Progress on 2026-08-26, and where it stopped.** With §6.8's policy module in
   place the installer runs: it draws its MFC GUI, takes a language, a serial, an
   email and an install path, and writes the registration to
   `Software\RT Systems V5\Alinco\DR-CS25 Programmer` in the prefix. So the Wine
   GUI layer is not the problem — that much is now evidence, not hope.
   It then aborts at the file-copy stage with `err:seh:call_seh_handlers invalid
   frame`, and installs nothing. Adding `mfc100u`/`msvcr100` via
   `winetricks -q vcrun2010` did not change the outcome (it changed the crash from
   heap corruption to the SEH abort, which is progress but not a fix).
   `wine-core.i686` is now in the image and a real `WINEARCH=win32` prefix works —
   **but it did not fix this, and made it worse**: in win32 the installer exits
   cleanly after the language dialog without reaching the serial prompt. Full
   detail and everything already ruled out is in §6.8c. The original question,
   serial control-line handling (DTR/RTS) on a cloning cable, has never been
   reached. Recommendation there is a Windows VM.
   Prefixes: `~/.local/share/wineprefixes/rtsystems` (win64), `rt32` (win32).
   Installers in `~/Downloads`; both are 32-bit.
2. **N1MM under Wine is expected to fail** (.NET over SQL Server Compact). If real
   N1MM is needed, use a Windows VM — install `org.gnome.Boxes` then, it is
   deliberately not baked. `not1mm` is the Linux alternative: `pipx install not1mm`.
3. **niri window rules are unverified.** Run `kb3lyb-check-window-rules` with the
   ham apps open. The `wine` and `sdrtrunk` patterns are the doubtful ones (§6.4).
4. **GridTracker2** is used daily on Windows and is packaged nowhere. It is a
   `$HOME` install, deliberately not baked.

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
