#!/usr/bin/env python3
# Run a command in the test VM over its serial console (unix socket), logging in
# as test/test if needed. Used by retest.sh for headless in-guest assertions —
# more reliable than SSH, which throttles under repeated probes.
#   python3 vm/serial-cmd.py 'rpm -q niri'
import socket, sys, time, re, os

SOCK = os.path.join(os.path.dirname(__file__), "serial.sock")
CMD = " ".join(sys.argv[1:]) or "true"

s = socket.socket(socket.AF_UNIX)
s.connect(SOCK)
s.settimeout(1.0)
buf = b""

def pump(seconds):
    global buf
    end = time.time() + seconds
    out = b""
    while time.time() < end:
        try:
            d = s.recv(4096)
            if d:
                out += d; buf += d
        except socket.timeout:
            pass
    return out

s.sendall(b"\n")
pump(2)
low = buf.lower()
if b"login:" in low:
    s.sendall(b"test\n"); pump(2)
    if b"password" in buf.lower():
        s.sendall(b"test\n"); pump(3)
elif b"password" in low:
    s.sendall(b"test\n"); pump(3)

s.sendall(b"echo __BEGIN__; " + CMD.encode() + b" 2>&1; echo __END__\n")
out = (pump(12) + pump(2)).decode(errors="replace")
m = re.search(r"__BEGIN__(.*)__END__", out, re.S)
print(m.group(1).strip() if m else out[-3000:])
try:
    s.sendall(b"exit\n")
except Exception:
    pass
