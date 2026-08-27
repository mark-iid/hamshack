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

> [!WARNING]
> **The hostname guard alone is NOT enough, and the client proved it.** After the
> guard was in place the client still kept appearing on the shack PC. The guard was
> working and was not the problem: the flatpak exports a **D-Bus activation
> service** (`com.nextcloudgmbh.Nextcloud.service`) to the host bus, so anything
> requesting that bus name starts the client — no autostart entry, no niri
> involvement, and nothing a spawn guard can intercept. It also writes its own
> `~/.var/app/.../config/autostart/Nextcloud.desktop` inside the sandbox.
>
> So on this machine the flatpak is **uninstalled outright** (2026-08-27), which
> removes the D-Bus service with it. Nextcloud here is the rclone mount and only the
> rclone mount. The guard stays for the laptop's sake. If the client is ever
> reinstalled here, expect it to start itself again regardless of the guard:
>
> ```bash
> ls /var/lib/flatpak/exports/share/dbus-1/services/ | grep -i nextcloud
> ```

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

### 6.8b Do NOT reach for `WINEARCH=win32` — a normal prefix runs 32-bit apps

Fedora's Wine is **new-WoW64**: it runs 32-bit Windows applications inside an
ordinary **64-bit** prefix. There is nothing to configure. Just:

```bash
export WINEPREFIX=~/.local/share/wineprefixes/<name>   # NO WINEARCH
wine wineboot -u
```

Asking for a 32-bit prefix fails with a message that sounds like a missing package
but is not:

```
wine: WINEARCH is set to 'win32' but this is not supported in wow64 mode.
```

**That message is not an instruction to install anything.** It means you asked for
something this Wine does not do and does not need to do. Verified 2026-08-26/27:
32-bit `cmd.exe` runs in a normal win64 prefix under SELinux Enforcing, and VARA HF
— a 32-bit application — installs and runs there (§6.9).

This cost a whole rebuild-and-reboot cycle, so it is worth stating what went wrong.
Pat's wiki says to use `WINEARCH=win32` for VARA. That advice predates new-WoW64.
Following it led to adding `wine-core.i686` (186 packages, 1.23 GB) to get the
classic `i386-unix` loader and a `/usr/bin/wine32` binary, because `/usr/bin/wine`
is an alternatives symlink resolving to `wine64` and refuses win32 prefixes. All of
that worked, and all of it was unnecessary: the win32 prefix made the RT Systems
installer behave *worse*, and VARA never needed it. The package has since been
removed again — see the comment in `recipes/common/hamradio.yml`.

> [!IMPORTANT]
> If 32-bit Windows binaries fail on this machine, the cause is **§6.8's SELinux
> `execmod` denial**, essentially every time. It is not a missing multilib package,
> and adding `wine-core.i686` will not fix it — that was tried and measured. Check
> `sudo semodule -l | grep kb3lyb` first.

### 6.8c RT Systems programmers — WORKING, via an older Wine in a toolbox

Solved 2026-08-27 after a long detour. **Both** programmers install, launch and draw
their channel grid — Alinco DR-CS25 and Wouxun KG-UV96. Three separate things were
wrong; each masked the next.

The second programmer needed no extra work: same prefix, same recipe, installer
exited cleanly with no COM errors, because `mfc42` and the registered FarPoint grid
are shared across RT Systems V5 apps. Expect any further RT Systems title to be the
same — install it into this prefix and it should simply work.

#### The recipe

```bash
toolbox create --distro fedora --release 41 --assumeyes wine41
toolbox run -c wine41 sudo dnf install -y wine winetricks      # gets wine 10.15

export P=~/.local/share/wineprefixes/rt-w10                    # NO WINEARCH
toolbox run -c wine41 env WINEPREFIX=$P wine wineboot -u
toolbox run -c wine41 env WINEPREFIX=$P winetricks -q win7 sound=alsa vcrun2010 mfc42
toolbox run -c wine41 env WINEPREFIX=$P wine ~/Downloads/DRCS25_Setup.exe
toolbox run -c wine41 env WINEPREFIX=$P wine regsvr32 'C:\windows\syswow64\FPSPRU80.ocx'

ln -sfn /dev/serial/by-id/usb-RT_Systems_CT29F_Radio_Cable_RTA04P95-if00-port0 \
        $P/dosdevices/com1

toolbox run -c wine41 env WINEPREFIX=$P \
  wine 'C:\RT Systems V5\Alinco\DRCS25_V5\RadioEngine_V5.exe'
```

#### The three problems, in the order they have to be solved

1. **SELinux `execmod`** (§6.8) blocks every 32-bit PE. Machine-wide, still needed —
   VARA depends on it too.
2. **Wine 11.0 corrupts its own heap** during the installer's file-copy stage:
   `free(): invalid size`, which is *glibc's* message, not Wine's. Reproduced under
   Windows 10, XP and 7 compatibility modes — the mode changes how far it gets, never
   whether it fails. **Wine 10.15 does not have this bug.** That is the whole reason
   for the toolbox; nothing else about the container matters.
3. **The channel grid is a separate COM component that the installer fails to
   register.** Symptom is a dialog saying *"attempted an unsupported operation"* and a
   blank white grid area, with the app otherwise responsive and idle.

#### Why problem 3 is worth reading before debugging anything similar

The visible error names nothing. The chain is:

```
"attempted an unsupported operation"          <- MFC reporting a COM failure
err:ole:com_get_class_object class {de52502e-f837-492b-ae14-a182531afaf4} not registered
  -> binary GUID search finds it in FPSPRU80.ocx   (FarPoint Spread 8 — the grid)
  -> regsvr32 FPSPRU80.ocx fails SILENTLY
  -> with output shown: "Library MFC42u.DLL not found"
  -> the grid is 2010-era and needs MFC 4.2 (VC++ 6), NOT the MFC 10 that
     RadioEngine_V5.exe itself uses. Hence winetricks mfc42 as well as vcrun2010.
```

Note the GUID is stored little-endian in the PE, so `grep` for the printed form finds
nothing — search for `uuid.UUID(...).bytes_le`.

> [!IMPORTANT]
> This lives in the **`wine41` toolbox container**, not in the image. It survives
> reboots, but a fresh install has none of it, and `toolbox rm wine41` destroys it.
> The image deliberately does not carry a second Wine version; if that becomes
> unacceptable, the alternative is a Windows VM, not pinning Wine in the recipe.

**Still untested: talking to a radio.** Installing and running is not programming a
radio. The cable is mapped to COM1 by its by-id path, and §6.5's DTR/RTS warning
applies to the cloning cable as much as to the FT-710 — treat first contact carefully.

### 6.9 Pat / Winlink — VARA, ARDOP, and the shared rigctld

Configured at `~/.config/pat/config.json` (mode 0600 — it holds a Winlink password).
Station is KB3LYB / EN90xm, taken from the log rather than typed from memory.

| transport | addr | native? | state |
|---|---|---|---|
| VARA HF | `127.0.0.1:8300` | no — Windows, under Wine | **working, registered, PROVEN ON AIR** 2026-08-27 |
| VARA FM | `127.0.0.1:8300` | no — Windows, under Wine | installed, untested |
| ARDOP | `127.0.0.1:8515` | **yes** — `ardopcf` | **untested — the binary is not on the machine yet** |

> [!NOTE]
> **ARDOP has not failed; it has never run.** `install-ardopcf.sh` went into the
> recipe on 2026-08-26, *after* the image this machine booted. Pat is configured
> correctly and nothing answers on 8515 because the modem is not installed. Get it
> with `sudo rpm-ostree upgrade` + reboot, then start it per session:
> `ardopcf 8515 <capture-device> <playback-device>`.

**Addresses are `127.0.0.1`, never `localhost`** — deliberately. `localhost` resolves
to `::1` first on this machine, and an IPv4-only listener is then simply refused.
That cost an hour on QLog↔rigctld (§6.5) and would have been the first thing to
suspect with ARDOP.

All three point at the rig named `ft710`, which is the **shared rigctld** from §6.5,
addressed as `127.0.0.1:4532`. Not `localhost` — see the IPv6 trap in that section.

**There is no native Linux VARA** — closed-source Windows only. Wine is the route,
and it WORKS. Installed and verified 2026-08-26: VARA HF v4.9.0 running, UI drawing,
status `2300 LISTEN`, listening on TCP 8300/8301.

#### The VARA recipe that actually works

```bash
export WINEPREFIX=~/.local/share/wineprefixes/winlink64   # NO WINEARCH
wine wineboot -u
winetricks -q winxp sound=alsa vb6run vcrun2015 dotnet35sp1   # dotnet is the slow one
cd "$WINEPREFIX/drive_c" && wine ~/Downloads/'VARA setup (Run as Administrator).exe' \
    /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
wine "$WINEPREFIX/drive_c/VARA/VARA.exe"
```

Two things that cost hours and are worth internalising:

1. **Do NOT use `WINEARCH=win32`.** Pat's wiki says to, and that advice predates
   new-WoW64. Fedora's Wine runs 32-bit Windows apps in an ORDINARY 64-bit prefix;
   asking for win32 fails with a misleading *"not supported in wow64 mode"*. A plain
   default prefix is correct, and VARA installed more cleanly in it (rc=0) than in
   the win32 prefix that was built to accommodate the wiki. **VARA does not need
   `wine-core.i686` at all** — that package has since been removed again; see §6.8b.
2. **VARA's installer is Inno Setup, so it installs silently.** `/VERYSILENT
   /SUPPRESSMSGBOXES /NORESTART` needs no GUI at all. Attempting to drive the wizard
   with `wtype` is a dead end — virtual-keyboard events do not reach XWayland clients
   under niri, so no keystroke ever lands.

> [!WARNING]
> **VARA binds `0.0.0.0:8300` and `0.0.0.0:8301`, not loopback**, and has no
> authentication of any kind. On this machine that exposes it on the LAN
> (192.168.x) and over Tailscale. Pat only ever needs `localhost`. VARA has no
> bind-address setting, so containing it means a firewall rule — unlike rigctld,
> which takes `-T 127.0.0.1` (§6.5).

Give VARA its own prefix, separate from the RT Systems experiments, so a broken
prefix cannot take the working modem down with it.

**`ptt_ctrl` is true on all three transports**, so Pat keys the transmitter through
rigctld when it connects. That is correct and necessary for Winlink, but it means
Pat is a third CAT consumer alongside QLog and CATTouch — see the contention note in
§6.5 if protocol errors appear once Pat is actually operating.

Still needed:

1. `secure_login_password` is empty. Set it with `pat configure`.
2. `ardopcf` — needs the image upgrade above.
3. Audio routing — VARA and ardopcf each need the FT-710's USB codec selected as
   their soundcard. That is configured in VARA's own UI and in ardopcf's device
   arguments, NOT in Pat, and it is the step most likely to be mistaken for a Pat
   misconfiguration.

`ardopcf` is started per session against a soundcard, not run as a service:

```bash
ardopcf 8515 <capture-device> <playback-device>
```

PTT stays with rigctld — do not also give ardopcf its own serial PTT, or two
processes own the CAT port.

### 6.10 QSSTV and WSJT-X — both on the shared rigctld

Same rule as everything else: **Hamlib NET rigctl at `127.0.0.1:4532`**, never a raw
device, never `localhost`.

| app | config | set |
|---|---|---|
| QSSTV | `~/.config/ON4QZ/qsstv_9.0.conf` | callsign, locator EN90xm, QTH; `radioModel` NET rigctl; `serialPort=127.0.0.1:4532` |
| WSJT-X | `~/.local/share/WSJT-X/WSJT-X.ini` | `Rig=Hamlib NET rigctl` (came from Windows), `CATNetworkPort=127.0.0.1:4532` |

Two traps in these files specifically:

- **QSSTV puts the NET rigctl address in `serialPort`**, not in a host/port field. It
  shipped as `/dev/ttyS0`, which looks plausible and is wrong for model 2.
- **QSSTV defaults to `activeRTS=true`.** RTS is PTT on this rig (§6.5). rigctld owns
  the port and does PTT over CAT, so QSSTV must not assert the lines itself —
  `activeRTS` and `activeDTR` are both forced false, and `enableSerialPTT` stays off.

WSJT-X's `.ini` came across from the Windows install, so it already had the right rig
model and `MyCall`/`MyGrid`, but `CATNetworkPort` was **empty** — the right model
pointing at nothing. Its `SoundInName`/`SoundOutName` are still Windows strings and
are set in the GUI.

Its log is the digital-only file from §6.7: 7,263 records, zero SSB/CW. Do not
replace it with the 8,584-record original.

### 6.11 QLog DX cluster, and QSSTV frequencies

**Cluster.** QLog wants the server as `[username@]hostname:port`. Configured in
`~/.config/hamradio/QLog.conf` under `[dxc]`:

```ini
last_server=KB3LYB@dxc.ve7cc.net:23
autoconnect=false
filter/dedup=true
filter/deduptime=30
filter/spotter/contregexp=NA
```

VE7CC runs **CC Cluster**, which has the richest server-side filtering of the common
nodes — so filtering can be pushed to the server with `set/filter` commands as well
as done in QLog. Alternatives: `dxc.w3lpl.net:7373` (Glenwood MD, the closest major
node to Pittsburgh) or `hamqth.com:7300` (QLog's own documented example).

> [!IMPORTANT]
> **Filter on SPOTTER continent, not DX continent.** `filter/spotter/contregexp=NA`
> shows only spots *posted by* North American stations, which is a proxy for "someone
> near me can hear this right now" — i.e. propagation that applies here. Filtering on
> the **DX** continent instead would hide the DX worth chasing, since rare stations
> are everywhere. This is the setting that makes a cluster useful rather than a
> firehose, and it is easy to get backwards.

`autoconnect` is deliberately **false** until a connection is confirmed by hand.

**QSSTV frequencies.** `[FREQSELECT]` in `~/.config/ON4QZ/qsstv_9.0.conf` holds four
PARALLEL lists — `frequencyList`, `modeList`, `passBandList`, `sbModeList`. Only the
first and last are set, to the standard SSTV calling frequencies:

| band | 160 | 80 | 40 | 20 | 17 | 15 | 12 | 10 | 6 | 2 |
|---|---|---|---|---|---|---|---|---|---|---|
| MHz | 1.916 | 3.845 | 7.171 | **14.230** | 18.160 | 21.340 | 24.975 | 28.680 | 50.680 | 145.500 |

14.230 is the international calling frequency and the one that is actually busy. USB
on HF, FM on 6 m and 2 m. If entries are ever added by hand, keep the lists the same
length — they are positional.

Both lists must be **fully populated and equal length**. Leaving `modeList` and
`passBandList` as `@Invalid()` while setting the other two makes QSSTV silently
discard the whole lot on exit — the format is `SSTV` and `Normal` respectively.

**QLog's cluster settings are NOT in QLog.conf.** They live in the `log_param` table
of `~/.local/share/hamradio/QLog/qlog.db`:

```bash
sqlite3 qlog.db "select name,value from log_param where name like 'dxc/%';"
```

Writing them into `~/.config/hamradio/QLog.conf` looks plausible — the binary
contains `dxc/*` key names and QSettings will happily store them — but nothing reads
them there. QSettings also preserves unknown keys, so a wrong guess persists across
restarts and looks like it worked.

### 6.11b WSJT-X window layout

`Mod+W` runs `scripts/wsjtx-layout`, which stacks WSJT-X's two windows in one
full-width column — waterfall on top at ~20%, main window below:

```
+----------------------------------+
|  WSJT-X - Wide Graph        ~20% |
+----------------------------------+
|  WSJT-X main                ~80% |
+----------------------------------+
```

Three things this needs that are not obvious:

1. **Both windows share the app-id `wsjtx`**, so they are told apart by TITLE — the
   waterfall contains "Wide Graph". The window rules in `config.kdl` set tiling and
   sizes; the script does the stacking.
2. **niri has no window-rule for "open into the existing column."** New windows always
   get their own column, so merging needs `consume-or-expel-window-left`, an action.
   Hence a script, same as `scripts/comms`.
3. **The script gathers onto an empty workspace first.** Without that,
   `move-column-to-first/last` reorder relative to every other window on the
   workspace and the consume merges the wrong pair.

Two traps found while building it: a consumed window lands at the **bottom** of the
target column, so the WATERFALL's column must be the survivor and the main window is
consumed into it — doing it the other way silently inverts the layout. And WSJT-X maps
a short-lived **splash** also titled "WSJT-X" (the real one carries a version, e.g.
"WSJT-X   v3.0.1"), so the script picks the tallest non-waterfall window rather than
the lowest id, and re-reads the ids after a settle.

### 6.12 Dark mode: the portal reads dconf, and `gsettings set` may write nothing

Electron apps (Slack, VS Code, Discord) and Qt6 read the **XDG portal**, not GSettings
directly. Check what they are actually being told:

```bash
gdbus call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Settings.Read \
  org.freedesktop.appearance color-scheme      # 0=light/none, 1=dark, 2=light
```

On 2026-08-27 that returned **0** while `gsettings get org.gnome.desktop.interface
color-scheme` returned `prefer-dark`, so Slack started in light mode. The two disagree
because they read different layers:

- `gsettings set` was a **silent no-op** — it wrote nothing to dconf, and
  `dconf read /org/gnome/desktop/interface/color-scheme` came back **empty**.
- The portal reads dconf. Empty means "no preference", i.e. light.

The fix is to force an explicit dconf entry:

```bash
dconf write /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
```

After which the portal reports `1`. **No portal configuration change was needed** —
routing Settings to the gtk backend was tried and made no difference, because the
backend was reading the right place and finding nothing there.

Note GTK apps looked dark throughout, because `GTK_THEME=Adwaita:dark` is set in the
niri `environment` block — an env var, a completely separate mechanism. That is why
`tqsl` and `gpredict` were fine while Slack was not, and why "some apps are dark" is
not evidence the system setting is correct.

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
- **RT Systems programmers work** (§6.8c) — BOTH of them: Alinco DR-CS25 and Wouxun
  KG-UV96 install, launch and draw their channel grid. Needed Wine 10.15 in a toolbox
  (Wine 11.0 corrupts its own heap during the install), plus `mfc42` and a manual
  `regsvr32` of the FarPoint grid control the installer fails to register.
  Programming an actual radio is still untested.
- **Winlink works and is PROVEN ON AIR** (§6.9) — VARA HF v4.9.0 under Wine,
  registered, driven by Pat over the shared rigctld. ARDOP is configured but its
  modem is not installed yet; it has never run, which is not the same as failing.
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
- **`wine-core.i686` is out, and adding it back is not the fix for anything.**
  It was added on 2026-08-26 and removed again on 2026-08-27 after being measured.
  The story, so it is not repeated: 32-bit Windows binaries failing is **always**
  the SELinux `execmod` denial (§6.8), which this package does not touch. It was
  added to enable a `WINEARCH=win32` prefix as a way past the DRCS25 SEH crash;
  the win32 prefix made that installer *worse*, and VARA HF then installed and ran
  perfectly in an ordinary win64 prefix with plain `wine` (§6.9). Fedora's Wine is
  new-WoW64 and runs 32-bit apps in a 64-bit prefix — `WINEARCH=win32` is neither
  needed nor supported, and the Pat wiki advice that said otherwise predates it.
  Cost while present: 186 packages / 1.23 GB. See §6.8b.
- **The logs need no deduplication.** See §6.7. Do not "tidy" them.
- **VARA's `0.0.0.0` bind is accepted — do not "fix" it.** VARA HF listens on
  `0.0.0.0:8300`/`8301` with no authentication, so it is reachable on the LAN and
  over Tailscale while running. VARA has no bind-address option, so the only lever
  is a firewall rule. The operator weighed this on 2026-08-27 and chose to leave it.
  Note it only listens while VARA is actually running, which is per operating
  session, not at boot.
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

1. **N1MM under Wine is expected to fail** (.NET over SQL Server Compact). If real
   N1MM is needed, use a Windows VM — install `org.gnome.Boxes` then, it is
   deliberately not baked. `not1mm` is the Linux alternative: `pipx install not1mm`.
2. **niri window rules are only partly verified.** The `wine` pattern WAS wrong and
   is fixed — it matched `^(?i)wine$` on the belief that niri matches the second
   WM_CLASS field, but niri reports the instance name, so a Wine window's app-id is
   the executable (`drcs25_setup.exe`, `vara.exe`). It now matches `.exe`, with VARA
   excepted so it tiles. `sdrtrunk` and the WSJT-X/fldigi/CHIRP patterns are still
   unchecked — run `kb3lyb-check-window-rules` with those apps open (§6.4).
3. **GridTracker2** is used daily on Windows and is packaged nowhere. It is a
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
