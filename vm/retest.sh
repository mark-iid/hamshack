#!/usr/bin/env bash
# Comprehensive VM re-test after §9.5/§9.6 landed a lot on top of the §9.4 boot.
# Split around the one sudo step (biib is rootful):
#
#   bash vm/retest.sh export        # rootless: refresh the oci from the current image
#   sudo bash vm/build-qcow2.sh     # build the qcow2
#   bash vm/retest.sh verify        # rootless: boot, assert in-guest, hand off to VNC
set -uo pipefail
cd "$(dirname "$0")/.."

# In-guest assertions. Kept as a readable script and base64'd onto the serial line
# so newlines don't confuse the console.
read -r -d '' CHECK <<'EOS'
for pair in \
  "render_node(niri needs it)|test -e /dev/dri/renderD128" \
  "niri installed|rpm -q niri" \
  "xwayland-satellite|rpm -q xwayland-satellite" \
  "VS Code installed|rpm -q code" \
  "tailscale installed|rpm -q tailscale" \
  "openconnect installed|rpm -q openconnect" \
  "rclone installed|rpm -q rclone" \
  "stow installed|rpm -q stow" \
  "fprintd installed|rpm -q fprintd" \
  "greetd active|systemctl is-active greetd" \
  "sddm not enabled|! systemctl is-enabled sddm" \
  "tailscaled enabled|systemctl is-enabled tailscaled" \
  "pam_fprintd wired|grep -q pam_fprintd /etc/authselect/system-auth" \
  "flatpak override seed|test -f /usr/share/factory/var/lib/flatpak/overrides/com.slack.Slack" \
  "bootstrap executable|test -x /usr/bin/kb3lyb-bootstrap" \
  "dcdebugmask karg|grep -q dcdebugmask /proc/cmdline" \
  "plymouth disabled karg|grep -q plymouth.enable=0 /proc/cmdline" ; do
  label=${pair%%|*}; cmd=${pair#*|}
  if eval "$cmd" >/dev/null 2>&1; then echo "PASS  $label"; else echo "FAIL  $label"; fi
done
EOS

case "${1:-}" in
  export)
    bash vm/export-image.sh
    ;;
  verify)
    qcow=$(find vm/output -name '*.qcow2' 2>/dev/null | head -1)
    [ -n "$qcow" ] || { echo "!! no qcow2 in vm/output — run: bash vm/retest.sh export && sudo bash vm/build-qcow2.sh"; exit 1; }
    echo ">>> booting the qcow2 for comprehensive verification"
    bash vm/boot-check.sh >/dev/null 2>&1 || true   # boots, screenshots greeter, leaves VM running
    sleep 5
    echo ">>> in-guest assertions (over serial):"
    b64=$(printf '%s' "$CHECK" | base64 -w0)
    python3 vm/serial-cmd.py "echo $b64 | base64 -d | bash"
    echo
    echo ">>> automated checks done. Human part (needs your eyes / a token):"
    echo "    1. VNC 127.0.0.1:5901, log in test/test — confirm niri renders (waybar, Mod+Return = terminal)."
    echo "    2. In a niri terminal: kb3lyb-bootstrap  (prompts for the dotfiles token; installs brew/SDKMAN/JetBrains)."
    echo "    Stop the VM when done: bash vm/boot-check.sh --shutdown"
    ;;
  *)
    echo "usage:"
    echo "  bash vm/retest.sh export   # refresh oci from current image (then: sudo bash vm/build-qcow2.sh)"
    echo "  bash vm/retest.sh verify   # boot qcow2, run in-guest assertions, hand off to VNC"
    ;;
esac
