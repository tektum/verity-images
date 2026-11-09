"""Exercise the PyPy runtime and the stdlib modules the image promises.

Usage: stdlib_probe.py PYPY_VERSION. Prints one line per check and exits
non-zero, naming every failed check, when any of them fails.
"""
import sys

failures = []


def check(name, condition, detail=""):
    if condition:
        print("ok", name)
    else:
        failures.append(name)
        print("FAIL", name, detail, file=sys.stderr)


def square(value):
    return value * value


def main():
    expected = tuple(int(part) for part in sys.argv[1].split("."))

    # Interpreter identity.
    import platform

    check("sys.implementation.name", sys.implementation.name == "pypy", sys.implementation.name)
    check("python language level", sys.version_info[:2] == (3, 11), sys.version)
    check("pypy version", tuple(sys.pypy_version_info[:3]) == expected, str(sys.pypy_version_info))
    check("platform.python_implementation", platform.python_implementation() == "PyPy")

    # The JIT is part of the promise: the interpreter is translated with it.
    import pypyjit

    check("jit module", callable(pypyjit.set_param))
    check("hot loop", sum(i % 3 for i in range(3000000)) == 3000000)

    # Bytecode is shipped, because the non-root user cannot write __pycache__.
    import importlib.util
    import json
    import os
    import ssl

    for module in (os, json, ssl):
        cached = importlib.util.cache_from_source(module.__file__)
        check("bytecode for " + module.__name__, os.path.isfile(cached), cached)

    # OpenSSL through the CFFI _ssl module, and the system root store.
    check("openssl 3", ssl.OPENSSL_VERSION.startswith("OpenSSL 3."), ssl.OPENSSL_VERSION)
    roots = ssl.create_default_context().cert_store_stats()["x509_ca"]
    check("default root store", roots > 50, "x509_ca=%d" % roots)

    import hashlib
    import hmac

    check("sha256", hashlib.sha256(b"abc").hexdigest() ==
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    check("sha3_256", hashlib.sha3_256(b"abc").hexdigest() ==
          "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    check("blake2b", hashlib.blake2b(b"abc", digest_size=32).hexdigest() ==
          "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
    check("pbkdf2", hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 1000, 16).hex() ==
          "632c2812e46d4604102ba7618e9d6d7d")
    check("hmac", hmac.new(b"key", b"msg", "sha256").hexdigest() ==
          "2d93cbc1be167bcb1637a4a23cbff01a7878f0c50ee833954ea5221bb1b8c628")

    # CFFI-built and RPython-built stdlib modules.
    import bz2
    import lzma
    import sqlite3
    import tempfile
    import zlib

    payload = b"verity " * 1000
    check("zlib", zlib.decompress(zlib.compress(payload)) == payload)
    check("bz2", bz2.decompress(bz2.compress(payload)) == payload)
    check("lzma", lzma.decompress(lzma.compress(payload)) == payload)

    connection = sqlite3.connect(":memory:")
    connection.execute("create table t (a integer, b text)")
    connection.executemany("insert into t values (?, ?)", [(1, "x"), (2, "y"), (3, "z")])
    check("sqlite3", connection.execute("select sum(a), count(b) from t").fetchone() == (6, 3))

    import dbm.gnu

    with tempfile.TemporaryDirectory() as directory:
        with dbm.gnu.open(os.path.join(directory, "probe.gdbm"), "n") as database:
            database[b"key"] = b"value"
            check("gdbm", database[b"key"] == b"value")

    import _curses  # noqa: F401  (the import is the check: it links ncurses)

    check("curses", True)

    # Foreign function interfaces.
    import cffi
    import ctypes

    libc = ctypes.CDLL("libc.so.6")
    libc.strlen.argtypes = [ctypes.c_char_p]
    libc.strlen.restype = ctypes.c_size_t
    check("ctypes", libc.strlen(b"pypy") == 4)

    ffi = cffi.FFI()
    ffi.cdef("size_t strlen(const char *);")
    check("cffi", ffi.dlopen(None).strlen(b"verity") == 6)

    import greenlet

    values = []
    child = greenlet.greenlet(lambda: values.append("child"))
    child.switch()
    check("greenlet", values == ["child"])

    # pyexpat runs on the system libexpat, not a copy vendored in the interpreter.
    import xml.etree.ElementTree as ET

    root = ET.fromstring("<a><b k='v'>text</b></a>")
    check("expat parse", root.find("b").attrib == {"k": "v"} and root.find("b").text == "text")
    with open("/proc/self/maps") as maps:
        check("system libexpat", "libexpat.so" in maps.read())
    try:
        ET.fromstring("<a><b></a>")
    except ET.ParseError:
        check("malformed xml rejected", True)
    else:
        check("malformed xml rejected", False, "parsed")
    bomb = ("<?xml version='1.0'?><!DOCTYPE l [<!ENTITY a 'aaaaaaaaaa'>" +
            "".join("<!ENTITY e%d '%s'>" % (n, ("&%s;" % ("a" if n == 0 else "e%d" % (n - 1))) * 10)
                    for n in range(9)) + "]><l>&e8;</l>")
    try:
        ET.fromstring(bomb)
    except ET.ParseError as error:
        check("entity expansion bomb rejected", "amplification" in str(error), str(error))
    else:
        check("entity expansion bomb rejected", False, "expanded")
    check("shallow entities still expand", len(ET.fromstring(bomb.replace("&e8;", "&e1;")).text) == 1000)

    # Concurrency and networking.
    import asyncio
    import multiprocessing
    import socket
    import threading

    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)

    def serve():
        connection, _ = server.accept()
        connection.sendall(connection.recv(16).upper())
        connection.close()

    thread = threading.Thread(target=serve)
    thread.start()
    client = socket.create_connection(server.getsockname(), timeout=10)
    client.sendall(b"verity")
    echoed = client.recv(16)
    thread.join()
    client.close()
    server.close()
    check("socket loopback", echoed == b"VERITY", repr(echoed))

    async def answer():
        await asyncio.sleep(0)
        return 42

    check("asyncio", asyncio.run(answer()) == 42)

    with multiprocessing.Pool(2) as pool:
        check("multiprocessing", pool.map(square, range(5)) == [0, 1, 4, 9, 16])

    if failures:
        print("probe failed: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("PROBE PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
