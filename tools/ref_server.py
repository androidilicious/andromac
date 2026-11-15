"""Reference implementation of the Mac side of the AndroMac wire protocol, using standard
HKDF-SHA256 and AES-256-GCM from the `cryptography` package (the same primitives CryptoKit provides).
Used to check that the phone-side code interoperates. Usage: ref_server.py PORT KEY_HEX"""
import socket, struct, sys, os
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def read(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b

def derive(psk, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(psk)

port, psk = int(sys.argv[1]), bytes.fromhex(sys.argv[2])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1); print("listening", flush=True)
c, _ = s.accept()
hello = read(c, 21)
assert hello[:4] == b"AMAC" and hello[4] == 1
server_salt = os.urandom(16)
c.sendall(b"AMAC\x01" + server_salt)
salt = hello[5:] + server_salt
rx, tx = AESGCM(derive(psk, salt, b"andromac v1 c2s")), AESGCM(derive(psk, salt, b"andromac v1 s2c"))
nonce = lambda i: b"\0" * 4 + struct.pack(">Q", i)

def recv(i):
    n = struct.unpack(">I", read(c, 4))[0]
    p = rx.decrypt(nonce(i), read(c, n), None)
    return p[0], p[1:]

def send(i, t, payload):
    ct = tx.encrypt(nonce(i), bytes([t]) + payload, None)
    c.sendall(struct.pack(">I", len(ct)) + ct)

t, p = recv(0); assert (t, p) == (1, b'{"t":"hello"}'), (t, p)
t, p = recv(1); assert t == 4 and p == bytes(range(256)) * 300, "binary frame mismatch"
send(0, 1, b'{"t":"hello","name":"ref"}')
send(1, 5, b"\x00" * 8 + b"thumb")
t, p = recv(2); assert (t, p) == (1, b'{"t":"ok"}'), (t, p)
print("SERVER OK")
