"""Build, install and import a pure Python wheel offline with the image's pip.

Exits non-zero, naming the failed step, when pip, setuptools, the wheel
directory used by ensurepip, or the bundled interpreter layout is broken.
"""
import os
import shutil
import subprocess
import sys
import tempfile

PIP = [sys.executable, "-m", "pip", "--disable-pip-version-check"]


def step(name, command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True, **kwargs)
    if result.returncode != 0:
        print("FAIL %s (exit %d)\n%s" % (name, result.returncode, result.stdout), file=sys.stderr)
        sys.exit(1)
    print("ok", name)
    return result.stdout


def main():
    work = tempfile.mkdtemp()
    wheels = os.path.join(work, "wheels")
    site = os.path.join(work, "site")
    # pip builds in the source tree, which the fixture mount does not allow.
    project = os.path.join(work, "demo-pkg")
    shutil.copytree("/fixture/demo-pkg", project)

    version = step("pip --version", PIP + ["--version"])
    if "(python 3.11)" not in version or "/opt/pypy/" not in version:
        print("FAIL pip --version reports an unexpected installation: " + version, file=sys.stderr)
        return 1

    listing = step("pip list", PIP + ["list", "--format=freeze"])
    for name in ("pip==", "setuptools=="):
        if name not in listing:
            print("FAIL pip list lacks %s\n%s" % (name, listing), file=sys.stderr)
            return 1

    step("pip wheel", PIP + ["wheel", "--no-index", "--no-build-isolation", "--no-deps",
                             "--wheel-dir", wheels, project])
    if not any(name.startswith("demo_pkg-1.0") and name.endswith("-py3-none-any.whl")
               for name in os.listdir(wheels)):
        print("FAIL no pure Python wheel was built: " + repr(os.listdir(wheels)), file=sys.stderr)
        return 1

    step("pip install --target", PIP + ["install", "--no-index", "--find-links", wheels,
                                         "--target", site, "demo-pkg"])
    greeting = step("import installed wheel", [sys.executable, "-c",
                    "import demo_pkg; print(demo_pkg.greet('verity'))"],
                    env=dict(os.environ, PYTHONPATH=site)).strip()
    if greeting != "hello verity from pypy":
        print("FAIL unexpected greeting: " + repr(greeting), file=sys.stderr)
        return 1

    # The interpreter's own tree must be closed to the image user. Check the
    # ownership and permission bits directly: the probes run on a read-only root,
    # which would refuse every write whatever those bits are.
    system_site = os.path.join(sys.prefix, "lib", "pypy3.11", "site-packages")
    for path in (sys.prefix, os.path.join(sys.prefix, "bin"), os.path.join(sys.prefix, "lib", "pypy3.11"),
                 system_site):
        info = os.stat(path)
        if info.st_uid != 0 or info.st_mode & 0o022:
            print("FAIL %s is writable by the image user: uid=%d mode=%o" % (path, info.st_uid, info.st_mode),
                  file=sys.stderr)
            return 1
    print("ok interpreter tree is root-owned and not group or world writable")

    # pip falls back to a user install unless told otherwise, so refuse the
    # fallback and expect it to leave the system site-packages untouched.
    denied = subprocess.run(PIP + ["install", "--no-index", "--find-links", wheels, "demo-pkg"],
                            env=dict(os.environ, PIP_USER="0", PYTHONNOUSERSITE="1"),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if denied.returncode == 0 or os.path.exists(os.path.join(system_site, "demo_pkg")):
        print("FAIL pip modified the system site-packages as a non-root user", file=sys.stderr)
        return 1
    print("ok pip does not install into the system site-packages")

    # venv runs ensurepip, which must find the Wolfi wheels.
    venv = os.path.join(work, "venv")
    step("venv", [sys.executable, "-m", "venv", venv])
    venv_pip = step("venv pip", [os.path.join(venv, "bin", "pip"), "--disable-pip-version-check",
                                 "--version"])
    if venv not in venv_pip:
        print("FAIL venv pip is not the venv's own: " + venv_pip, file=sys.stderr)
        return 1
    step("venv install", [os.path.join(venv, "bin", "pip"), "--disable-pip-version-check", "install",
                          "--no-index", "--find-links", wheels, "demo-pkg"])
    greeting = step("import from venv", [os.path.join(venv, "bin", "pypy3"), "-c",
                    "import demo_pkg; print(demo_pkg.greet('venv'))"]).strip()
    if greeting != "hello venv from pypy":
        print("FAIL unexpected venv greeting: " + repr(greeting), file=sys.stderr)
        return 1

    print("PIP PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
