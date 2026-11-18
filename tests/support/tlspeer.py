"""The independent TLS peer of `tests/test_remote_tls.nim` (DECISIONS G128, step 5-2c).

pyOpenSSL (OpenSSL, not the carrier's BoringSSL) on one side of a connection, with a key and a
certificate it made itself, so that a mistake the carrier shares with its own test peer still shows.
Test only: nothing in the core imports or ships this file.

    tlspeer.py keygen DIR
    tlspeer.py server DIR PEER_CERT [--tls12] [--p256-only]
    tlspeer.py client DIR PEER_CERT PORT [--tls12] [--no-cert] [--body-len N]

`keygen` writes `DIR/key.pem` and `DIR/cert.der`. `server` prints `port=N` once it listens and serves
one connection, echoing what it reads. `client` sends one frame (TRANSPORT §2.1: a 4-byte big-endian
length, then the body) and expects it back. Both end by printing a report of `key=value` lines:

    handshake  ok, or failed
    error      why the handshake failed
    version    the negotiated TLS version
    group      the negotiated key-exchange group
    binding    RFC 9266 `tls-exporter`, in hex (TRANSPORT §8.4.1 l.1279-1282)
    sni        the server name a server received
    echo       client: ok, or why the frame did not come back
    close      clean when the peer ended with close_notify, else why not
"""

import argparse
import datetime
import os
import signal
import socket
import struct
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from OpenSSL import SSL, crypto

EXPORTER_LABEL = b"EXPORTER-Channel-Binding"
EXPORTER_LEN = 32
DEADLINE_S = 600  # the suite kills a peer far sooner; this only stops an orphan


def keygen(directory):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, "tlspeer")])
    now = datetime.datetime.now(datetime.timezone.utc)
    usage = x509.KeyUsage(
        digital_signature=True,
        content_commitment=False,
        key_encipherment=False,
        data_encipherment=False,
        key_agreement=False,
        key_cert_sign=False,
        crl_sign=False,
        encipher_only=False,
        decipher_only=False,
    )
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(usage, critical=True)
        .sign(key, hashes.SHA256())
    )
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    with open(os.path.join(directory, "key.pem"), "wb") as f:
        f.write(pem)
    with open(os.path.join(directory, "cert.der"), "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.DER))


def context(args):
    """TLS 1.3 by default; the peer's certificate must be exactly `PEER_CERT`."""
    with open(args.peer_cert, "rb") as f:
        expected = f.read()

    def pinned(_conn, cert, _errnum, _depth, _ok):
        der = cert.to_cryptography().public_bytes(serialization.Encoding.DER)
        return der == expected

    version = SSL.TLS1_2_VERSION if args.tls12 else SSL.TLS1_3_VERSION
    ctx = SSL.Context(SSL.TLS_METHOD)
    ctx.set_min_proto_version(version)
    ctx.set_max_proto_version(version)
    ctx.set_verify(SSL.VERIFY_PEER | SSL.VERIFY_FAIL_IF_NO_PEER_CERT, pinned)
    if getattr(args, "p256_only", False):
        ctx.set_tmp_ecdh(ec.SECP256R1())
    if not getattr(args, "no_cert", False):
        with open(os.path.join(args.dir, "key.pem"), "rb") as f:
            ctx.use_privatekey(crypto.load_privatekey(crypto.FILETYPE_PEM, f.read()))
        with open(os.path.join(args.dir, "cert.der"), "rb") as f:
            ctx.use_certificate(crypto.load_certificate(crypto.FILETYPE_ASN1, f.read()))
    return ctx


def say(key, value):
    print(f"{key}={value}", flush=True)


def one_line(error):
    return " ".join(str(error).split())


def group_name(conn):
    # pyOpenSSL 25.1 has no public call for this; cryptography's binding does.
    name = SSL._lib.SSL_get0_group_name(conn._ssl)
    return SSL._ffi.string(name).decode() if name != SSL._ffi.NULL else "none"


def handshake(conn):
    """Reports the handshake; True when it completed."""
    try:
        conn.do_handshake()
    except (SSL.Error, OSError) as e:
        say("handshake", "failed")
        say("error", one_line(e))
        return False
    say("handshake", "ok")
    say("version", conn.get_protocol_version_name())
    say("group", group_name(conn))
    say("binding", conn.export_keying_material(EXPORTER_LABEL, EXPORTER_LEN, b"").hex())
    return True


def read_exactly(conn, n):
    data = bytearray()
    while len(data) < n:
        data += conn.recv(min(n - len(data), 65536))
    return bytes(data)


def run_server(args):
    listener = socket.create_server(("127.0.0.1", 0))
    say("port", listener.getsockname()[1])
    sock, _ = listener.accept()
    conn = SSL.Connection(context(args), sock)
    conn.set_accept_state()
    if not handshake(conn):
        return
    name = conn.get_servername()
    say("sni", name.decode() if name else "")
    try:
        while True:
            conn.sendall(conn.recv(65536))
    except SSL.ZeroReturnError:
        say("close", "clean")
        conn.shutdown()
    except (SSL.Error, OSError) as e:
        say("close", one_line(e))


def run_client(args):
    sock = socket.create_connection(("127.0.0.1", args.port))
    conn = SSL.Connection(context(args), sock)
    conn.set_connect_state()
    if not handshake(conn):
        return
    body = bytes(i % 251 for i in range(args.body_len))
    frame = struct.pack(">I", len(body)) + body
    try:
        conn.sendall(frame)
        echoed = read_exactly(conn, len(frame))
        say("echo", "ok" if echoed == frame else "different bytes")
    except (SSL.Error, OSError) as e:
        say("echo", one_line(e) or type(e).__name__)
        return
    try:
        conn.shutdown()
        while True:
            conn.recv(65536)
    except SSL.ZeroReturnError:
        say("close", "clean")
    except (SSL.Error, OSError) as e:
        say("close", one_line(e) or type(e).__name__)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("keygen").add_argument("dir")
    server = commands.add_parser("server")
    client = commands.add_parser("client")
    for p in (server, client):
        p.add_argument("dir")
        p.add_argument("peer_cert")
        p.add_argument("--tls12", action="store_true")
    server.add_argument("--p256-only", action="store_true")
    client.add_argument("port", type=int)
    client.add_argument("--no-cert", action="store_true")
    client.add_argument("--body-len", type=int, default=100_000)
    args = parser.parse_args()

    signal.alarm(DEADLINE_S)
    if args.command == "keygen":
        keygen(args.dir)
    elif args.command == "server":
        run_server(args)
    else:
        run_client(args)


if __name__ == "__main__":
    sys.exit(main())
