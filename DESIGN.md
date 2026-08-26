# kb3lyb-shack: design

The source of truth for *what* this image is and *why*. The operations runbook is
[SETUP.md](SETUP.md); the recipe itself is the source of truth for exact packages.

---

## 1. Context

A ham shack PC, replacing a Windows 10 IoT Enterprise LTSC install on the same
hardware. It is a sibling of `kb3lyb-sway` (the Framework 13 laptop image) and
deliberately shares its session stack, update model and tooling, so that lessons
learned on one apply to the other.

### The hardware, as measured

Read off the running machine on 2026-08-25 over SSH, not assumed. This matters:
the machine was believed to be a **G4 Mini** and is not.

| | |
|---|---|
| Model | **HP EliteDesk 800 G3 DM 65W** |
| CPU | Intel Core i5-6500 — Skylake, **4 cores / 4 threads (no HT)**, 3.2 GHz |
| GPU | Intel **HD Graphics 530** (Gen9) |
| RAM | 16 GB |
| Storage | 256 GB WD PC SN740 NVMe — **single disk** |
| Network | wired ethernet |
| Displays | multi-head desk (currently one head at 1600x900) |

Two consequences follow directly and are handled in the recipe:

- VA-API comes from **`intel-media-driver`** (iHD), which covers Gen9. The
  laptop's `mesa-va-drivers-freeworld` is the AMD path and would install cleanly
  while doing nothing. `intel-media-driver` is in RPM Fusion **nonfree**, not free
  — see `recipes/common/codecs.yml`.
- **The 256 GB disk is the binding constraint on this machine**, not the CPU. See
  §6.

### The radio interfaces attached

Enumerated from the Windows install, because "will my cables work" is the
question that decides whether this migration is viable at all:

| Device | ID | Linux driver | Status |
|---|---|---|---|
| RT Systems USB-29F radio cable (COM8) | `2100:9E55` | `ftdi_sio` | **supported in-tree** |
| Silicon Labs dual CP2105 (COM6/COM7) | `10C4:EA70` | `cp210x` | supported |
| FTDI FT232R x2 (COM9, COM15) | `0403:6001` | `ftdi_sio` | supported |
| CH340 (COM19) | `1A86:7523` | `ch341` | supported |
| USB Audio Device | — | `snd-usb-audio` | supported |

The RT Systems one is the notable result. RT Systems ships FTDI cables under
**their own vendor ID `0x2100`**, so a reasonable person would expect the generic
FTDI driver to ignore them. It does not: the kernel's `ftdi_sio` carries 28 RT
Systems PIDs (`9001`, `9E50`–`9E6A`), and `9E55` is among them. **No udev rule, no
`new_id` write, and no out-of-tree driver is needed.** Verified against this
machine's own `modinfo ftdi_sio`.

---

## 2. Locked decisions

1. **Separate repo from `frameworkimage`.** Two images, two CI pipelines. A broken
   shack build must not be able to red-X the laptop, and neither recipe should
   carry `if this machine` conditionals.
2. **Same base and session as the laptop** — `sway-atomic`, niri, greetd/tuigreet,
   waybar, mako, fuzzel. Reusing a stack that is already debugged is worth more
   than picking a theoretically better fit.
3. **Ham apps float; everything else tiles.** See §3.
4. **SSH over Tailscale for admin; no remote GUI.** The box is operated at its own
   keyboard. A Wayland remote-desktop stack is a lot of moving parts to maintain
   for a capability that is not wanted.
5. **`$HOME`-scoped installers are not baked** — same rule as the laptop image.
   This is what keeps `not1mm` and GridTracker out of the recipe (§4).
6. **Out-of-repo fetches are pinned by version AND SHA256.** The image is
   cosign-signed at the end of the build; an unpinned fetch makes that signature
   attest to something nobody reviewed.

### What this machine carries that the laptop does, and what it drops

The starting point is "the same setup as the laptop" — Evolution, the Flatpak app
set, VS Code, the dev toolchain, ghostty, dotfiles. That is deliberate: this is a
daily driver that also runs the shack, not an appliance. The divergences were
chosen one at a time on 2026-08-25 rather than by trimming to taste:

| Dropped | Why |
|---|---|
| `kismet` | A wireless survey tool on a wired desktop. It also dragged in a setuid-scoping script that **hard-fails when kismet is absent**, so that script is removed from this repo rather than left to break a future build. |
| `fr.handbrake.ghb` | Not wanted here. |
| `org.gnome.Boxes` | Install by hand if a Windows VM is ever needed for N1MM or an RT Systems programmer. No reason to carry it on every build until that day. |
| SDKMAN (bootstrap) | A Java toolchain manager, present on the laptop for SailPoint IIQ work. Nothing here needs it — note that sdrtrunk ships its **own** bundled JRE. |
| JetBrains Toolbox (bootstrap) | Explicitly not wanted. |
| voice toolbox (bootstrap) | Compiles whisper.cpp in a container on every bootstrap, for dictation that has nothing to do with operating a radio. `voice-setup` still exists in dotfiles if it is ever wanted. |

Kept on purpose, where the reasoning is not obvious:

- **Homebrew and its Brewfile.** Removing it was considered and rejected — the
  dotfiles `.zshrc` sources its shell plugins from brew, so dropping it would have
  broken the shell before it saved anything worth having.
- **`org.audacityteam.Audacity`.** It earns its place on a ham machine: recording
  off the rig, filtering, and inspecting WAVs.
- **VS Code and the C/C++ toolchain** (~1.6 GB together). The toolchain is not
  purely developer comfort — `pipx install not1mm` can need a compiler to build a
  wheel, and that failure is obscure when it happens.
- **`org.gimp.GIMP`**, **Slack/Teams/Zoom**, **Bruno**.

The removals are deliberate rather than flagged. A flag that defaults to "on" is
how these things come back.

---

## 3. niri, tuned for software that hates tiling

Ham software is overwhelmingly floating-window software written against toolkits
that predate tiling. WSJT-X is Qt with a waterfall that needs vertical room;
fldigi is FLTK/X11; `chirp+wx` is wxPython. Tiled into columns, WSJT-X's waterfall
and decode list fight for the same squeezed height, and child dialogs get shoved
into columns of their own.

So `files/system/etc/niri/config.kdl` carries `open-floating` window rules for the
ham apps, with fixed sizes for the two that most need them (WSJT-X, fldigi).

Two things about that file that will not be obvious later:

- **The `app-id` values are best-effort and need verifying on the machine.** niri
  matches Wayland `app-id`, and `WM_CLASS` for Xwayland clients. Neither can be
  read off a package. A rule that matches nothing fails **silently** — which is
  precisely how this file will rot. `niri msg windows` prints the truth.
- **`xwayland-satellite` is not optional here.** fldigi and `chirp+wx` are X11
  clients. Without it they have no server to open on.

Displays are at **scale 1**, not the laptop's 1.35. Most of this image's GUI is
Xwayland, and fractional scaling on Xwayland produces blurry upscaled bitmaps. 1x
is correct here, not a compromise.

---

## 4. The ham stack, and what is deliberately absent

Fedora's ham packaging is far better than its reputation: of the whole stack,
only three items needed out-of-repo handling. Everything was verified by
`repoquery` against a clean Fedora 44 container on 2026-08-25.

**Fetched, pinned, checksummed** (`files/scripts/install-*.sh`):

- **sdrtrunk** — packaged nowhere. Upstream ships a jlink app-image that carries
  its own JRE, so it adds no Java dependency and cannot be broken by a system JDK
  bump.
- **Pat** (Winlink) — no RPM exists anywhere; single static Go binary.

**Deliberately not baked:**

- **GridTracker2** — packaged nowhere and `$HOME`-shaped (NW.js). Belongs to the
  dotfiles bootstrap. It *is* actively used on the Windows box, so this is a real
  gap to close there, not an oversight.
- **not1mm** — the Linux contest logger (§5). PyQt6, PyPI-only, and releasing
  almost daily. Baking a fast-moving pip app into a signed image means rebuilding
  the image to take a bugfix. `pipx` is in the recipe; the app is not.

### Three traps that produce a green build and a broken machine

Each is asserted by `files/scripts/image-assert.sh`, because prose cannot fail a
build.

1. **`chirp` is not CHIRP.** Plain `chirp` installs `/usr/bin/chirpc`, a CLI. The
   wxPython GUI is in **`chirp+wx`**.
2. **`/opt` is a symlink to `/var/opt`.** `/var` is machine state, not image
   content, so a build-time write to `/opt` (or `/usr/local`, which is
   `/var/usrlocal`) is silently discarded at commit. Image-side installs go to
   **`/usr/lib/opt`**, with a tmpfiles symlink back at boot.
3. **Wine's 32-bit story is not what it looks like** — see §5.

---

## 5. Migrating off the Windows install

The Windows box was inventoried over SSH (65 installed products). The interesting
half:

| Windows app | Linux plan |
|---|---|
| WSJT-X 3.0.1 | **wsjtx 3.0.1** — Fedora carries the identical version |
| Fldigi 4.2.11 / flmsg / flamp | fldigi 4.2.13, flmsg, flamp — all in Fedora |
| **QLog 0.50.0** | **qlog 0.52.0** — Fedora is *newer*; SQLite + ADIF, so it is an import, not a conversion |
| Winlink Express | **Pat** |
| MMSSTV | **qsstv** |
| CHIRP | **chirp+wx** (all `.img` files already live in Nextcloud) |
| Trusted QSL 2.8.4 | `trustedqsl` (binary is `tqsl`) |
| BktTimeSync / JTSync | `chrony` — already in the base |
| com0com (virtual serial pairs) | **`socat`** — `socat -d -d pty,raw,echo=0 pty,raw,echo=0` |
| ITS HF Propagation | not packaged in Fedora; use the online VOACAP |
| **N1MM Logger+** | **not1mm** — see below |
| GridTracker2 | GridTracker2 has Linux builds; dotfiles-scoped |
| Ham Radio Deluxe, Win4Yaesu/IcomSuite, Log4OM, N3FJP ACLog, CW Skimmer, CwGet, JTAlert, WK3Tools | **no Linux equivalent.** hamlib/`rigctld` + flrig cover the rig-control half; the rest are genuine losses |

### N1MM Logger+ under Wine: expect this not to work

It is VB.NET on .NET Framework, backed by SQL Server Compact, with heavy Windows
interop, serial, WinKey and UDP broadcast. N1MM's own project does not support
Wine, and the combination of .NET Framework + SQL CE is one of the harder cases
Wine has. Treat "N1MM under Wine" as unlikely to be a dependable contest-day tool.
If real N1MM is required, the honest answer is a Windows VM with USB passthrough,
not more Wine tuning.

**not1mm** (`mbridak/not1mm`, GPL-3.0) is the purpose-built alternative: a Linux
contest logger explicitly modelled on N1MM, PyQt6, actively developed. Not in
Fedora; install with `pipx`.

### Wine and the RT Systems programmers

Only **two** RT Systems titles are licensed here — `DRCS25` (Alinco DR-CS25) and
`KGUV96` (Wouxun KG-UV96) — plus their FTDI driver package. Both radios' saved
data is two small `.dat` files.

On the Wine packaging itself, the obvious reasoning is **wrong**, and the recipe
says so at length. It is *not* true that 32-bit Windows apps need `wine-core.i686`.
Verified by `rpm -ql` inside the built image:

```
wine-core.x86_64  ->  wine/i386-windows   (827 32-bit PE DLLs)
                      wine/x86_64-unix    (64-bit host loader)
wine-core.i686    ->  wine/i386-unix      (32-bit host loader)
```

The 64-bit package alone runs 32-bit Windows binaries — that is what new WoW64 is.
The i686 package adds the *classic* 32-bit host loader, which matters only for
apps needing genuinely native 32-bit host libraries. It is currently kept as
insurance, and the cost is not small: **~120 packages becomes 733, of which 195
are i686.**

---

## 6. Open questions

Listed because an image whose uncertainties are undocumented drifts silently.

1. **Does the RT Systems software actually work under Wine?** Untested. The cable
   is supported by the kernel, which was the risk everyone expects; the app is the
   risk nobody checks. Wine's serial support is historically weak on control-line
   games (DTR/RTS, non-standard baud), which is what a cloning cable does.
2. ~~**Can CHIRP replace RT Systems outright?**~~ **ANSWERED — NO.** Checked
   against the installed CHIRP 0.4.0 (528 models) on 2026-08-25. Neither radio is
   supported:

   - Alinco: DJ-G7EG, DJ-G7T, DJ175, DJ596, DR03T, DR06T, DR135T, DR235T, DR435T,
     DR735T — **no DR-CS25**
   - Wouxun: KG-1000G(+), KG-805G, KG-816/818, KG-935G(+/H), KG-UV6, KG-UV8D(+/E/H),
     KG-UV8H, KG-UV920P-A, KG-UV980P, KG-UV9D Plus, KG-UV9G Pro, KG-UV9GX, KG-UV9K,
     KG-UV9PX, KG-UVD1P — **no KG-UV96**

   Model names confirmed from the programmers' own DLL version resources
   (`DR-CS25 V5.DLL`, `KG-UV96 V5.DLL`), not inferred from folder names.

   So Wine is load-bearing, not a nice-to-have. One encouraging detail: the
   programmers are **native Win32/MFC** — `RadioEngine_V5.exe` driving a per-radio
   `.dll` + `.ddt`, linked against `mfc100u.dll` (Visual C++ 2010). MFC apps
   historically run well under Wine. This is a materially better prospect than
   N1MM, which is .NET over SQL Server Compact. The open risk stays the serial
   side — control-line handling on a cloning cable — not the GUI.
3. **Can `wine-core.i686` be dropped?** If the programmers work under plain new
   WoW64, drop it. 195 packages of multilib is a lot to carry for insurance
   nobody is claiming on.
4. **Can `cqrlog` be dropped?** It hard-depends on `mariadb-server` (~78 MiB) — a
   database daemon riding along for a backup logger. If QLog proves out, this is
   the single biggest easy win in the recipe.
5. **Are the niri `app-id` patterns right?** Verify with `niri msg windows`.
6. **Are the display connector names right?** `DP-1`/`DP-2` in the baked config are
   placeholders. Verify with `niri msg outputs`.

---

## 7. The disk is the real constraint

Not the CPU. The i5-6500 is comfortable for FT8, fldigi, Winlink, packet and
logging — those are near-idle workloads. It is adequate but not generous for
sdrtrunk decoding trunked systems, where **4 cores with no hyperthreading** is the
number that matters and heavy multi-site trunking is where it will run out.

The 256 GB NVMe is tighter than it looks, because this image is not small:

- the `sway-atomic` base, plus ~394 packages of ham stack,
- plus Wine at 733 packages (`wine-core` alone is ~1.3 GB installed),
- plus sdrtrunk at ~200 MB,
- and rpm-ostree keeps **two deployments** so a bad update can be rolled back.

That is a substantial fraction of the disk before any user data. And SDR I/Q
recording, if used at all, is measured in **tens of GB per hour**.

The G3 DM chassis has an M.2 slot plus a 2.5" bay. Adding a 2.5" SSD for
recordings and logs — keeping the NVMe for the OS — is the cheapest way to remove
this constraint, and is worth doing before install rather than after.

---

## 7b. A karg in the image is not a karg on the machine

`/usr/lib/bootc/kargs.d/` entries are applied when a deployment transitions —
rebase or install — not on every upgrade. Adding a karg to the image therefore
does nothing to machines already running that image lineage, and nothing reports
the discrepancy: the file is in `/usr/lib/bootc/kargs.d/`, `image-assert.sh`
confirms it is there, and `/proc/cmdline` simply lacks it.

Discovered 2026-08-26 with `consoleblank=1200`, and on inspection the laptop image
had been quietly suffering the same thing: of its three kargs, only
`amdgpu.dcdebugmask` (present at the original rebase) is on the running cmdline.
`plymouth.enable=0` and `loglevel=3` were added later and have never applied —
`quiet` and `rhgb`, which they exist to displace, are still on the cmdline.

The build-time assertion is still worth having: it proves the image *declares* the
karg. It cannot prove the kernel received it, because that is host state, which is
the same boundary described in the image-assert header. The host-side step is in
SETUP §6.0c.

Inherited from the laptop image, unchanged:

- Nightly CI build against a **pinned** Fedora version; the version bump arrives
  as an automated PR, never a floating tag.
- A broken build means "no new image today" — the machine keeps running the last
  good signed deployment. That safety property is the entire reason for building
  in CI rather than on the machine.
- `rpm-ostreed-automatic` **stages** updates (`policy=stage`); they take effect on
  the next boot.
- `recipes/ham-test.yml` and `recipes/codec-test.yml` depsolve the two fragile
  modules in isolation, so a version bump breaks in a 90-second targeted build
  rather than a 20-minute full one.

---

## 9. Clean install

The machine has **one disk** and it currently holds a licensed Windows 10 IoT
Enterprise LTSC install. Wiping it destroys that install; capture whatever is
needed first.

Already pulled to `~/src/kb3lyb-backup-20260825/`:

- `Log4OM_ADIF_20260826005047.adi` — **5,804 QSOs** (also in Nextcloud)
- WSJT-X: `wsjtx_log.adi`, `ALL.TXT`, `WSJT-X.ini`, WSPR history
- `fldigi.files/` and `NBEMS.files/`
- RT Systems: `DRCS25.dat`, `KGUV96.dat`

CHIRP `.img` files already live in Nextcloud and need no separate backup.

Also captured (2026-08-25), as two archives:

- `kb3lyb-shack-backup.tar.gz` (228 MB) — Log4OM SQLite incl. `Log4OMNG.SQLite`,
  HRD, N1MM, GridTracker2, JTAlert, CHIRP appdata, MSHV, Win4YaesuSuite,
  Affirmatech/N3FJP, RT Systems, Desktop, `.ssh`
- `kb3lyb-winlink.tar.gz` (63 MB) — `C:\RMS Express`

Caches (`Cache/`, `GPUCache/`, Log4OM's `temp/`) were excluded — regenerable, and
Log4OM's `temp/EN.dat` alone is 214 MB.

**The logs need no deduplication.** The Log4OM export is already clean; the
apparent duplication lives in `wsjtx_log.adi`, which is a display cache for
worked-before highlighting rather than a log of record. See SETUP §6.7 — that
section exists specifically to stop a future attempt at "tidying" the logs from
destroying LoTW/eQSL confirmations.
