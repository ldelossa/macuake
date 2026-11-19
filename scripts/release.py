#!/usr/bin/env python3
"""Local, credential-preserving release tooling for ldelossa/macuake.

No command installs an app, starts it, changes Gatekeeper, exports a key, or
writes user preferences. Publishing requires an explicit clean main checkout.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_REPO = "ldelossa/macuake"
TAP_REPO = "ldelossa/homebrew-macuake"
APP_NAME = "Macuake"
BUNDLE_ID = "com.maquake.app"
ARCHIVE_NAME = "Macuake-arm64.zip"
SOURCE_NAME = "Macuake-source-materials.zip"


def run(args, *, cwd=ROOT, env=None, capture=False, check=True):
    args = [str(arg) for arg in args]
    print("+ " + shlex.join(args), flush=True)
    return subprocess.run(args, cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None, check=check)


def output(args, *, cwd=ROOT, env=None):
    return run(args, cwd=cwd, env=env, capture=True).stdout.strip()


def version_string(value):
    if not re.fullmatch(r"\d{1,4}\.\d{1,2}\.\d{1,2}", value):
        raise ValueError("Use a numeric release version such as 0.3.2")
    return value


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def remote_matches(url, repository):
    return url in (f"git@github.com:{repository}.git", f"https://github.com/{repository}.git",
                   f"https://github.com/{repository}")


def clean_main(path, repository):
    if Path(output(["git", "rev-parse", "--show-toplevel"], cwd=path)).resolve() != Path(path).resolve():
        raise RuntimeError("STOP: provide the actual repository root, not a nested directory")
    fetch_url = output(["git", "remote", "get-url", "origin"], cwd=path)
    push_urls = output(["git", "remote", "get-url", "--push", "--all", "origin"], cwd=path).splitlines()
    if not remote_matches(fetch_url, repository) or len(push_urls) != 1 or not remote_matches(push_urls[0], repository):
        raise RuntimeError(f"STOP: origin fetch/push URLs are not the approved {repository} repository")
    if output(["git", "branch", "--show-current"], cwd=path) != "main":
        raise RuntimeError(f"STOP: {repository} must be checked out on main")
    if output(["git", "status", "--porcelain"], cwd=path):
        raise RuntimeError(f"STOP: {repository} has uncommitted changes")
    head = output(["git", "rev-parse", "HEAD"], cwd=path)
    remote = output(["git", "ls-remote", "origin", "refs/heads/main"], cwd=path).split()
    if not remote or remote[0] != head:
        raise RuntimeError(f"STOP: {repository} main is not identical to pushed origin/main")
    return head


def dependency(*, replace=False):
    manifest = json.loads((ROOT / "Dependencies/GhosttyKit.json").read_text())
    tree = output(["git", "ls-tree", "HEAD", "vendor/ghostty"]).split()
    if len(tree) < 3 or tree[2] != manifest["commit"]:
        raise RuntimeError("STOP: Ghostty gitlink does not match the checksum manifest")
    cache = ROOT / "build/dependencies"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (manifest["commit"] + ".tar.gz")
    if not archive.exists() or sha256(archive) != manifest["sha256"]:
        url = (f'https://github.com/{manifest["repository"]}/releases/download/'
               f'{manifest["tag"]}/{manifest["asset"]}')
        with tempfile.TemporaryDirectory(prefix="ghostty-download-", dir=cache) as folder:
            downloaded = Path(folder) / manifest["asset"]
            attempt = run(["curl", "--fail", "--location", "--retry", "3",
                           "--proto", "=https", "--proto-redir", "=https",
                           "--output", downloaded, url], check=False)
            if attempt.returncode != 0:
                run(["gh", "release", "download", manifest["tag"], "--repo", manifest["repository"],
                     "--pattern", manifest["asset"], "--dir", folder, "--clobber"])
            if sha256(downloaded) != manifest["sha256"]:
                raise RuntimeError("STOP: downloaded GhosttyKit checksum mismatch")
            downloaded.replace(archive)
    target = ROOT / "vendor/ghostty/macos/GhosttyKit.xcframework"
    with tempfile.TemporaryDirectory(prefix="ghostty-extract-", dir=cache) as folder:
        folder = Path(folder)
        with tarfile.open(archive, "r:gz") as source:
            for member in source.getmembers():
                parts = Path(member.name).parts
                if not parts or Path(member.name).is_absolute() or ".." in parts:
                    raise RuntimeError("STOP: unsafe dependency archive path")
                # BSD tar consumes AppleDouble sidecars as xattrs rather than
                # files. They are not xcframework code/header content.
                if any(part.startswith("._") or part in (".DS_Store", "__MACOSX") for part in parts):
                    continue
                destination = folder / member.name
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as incoming, destination.open("wb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
                    destination.chmod(member.mode & 0o777)
                else:
                    raise RuntimeError("STOP: unexpected dependency archive link or special file")
        expected = folder / "GhosttyKit.xcframework"
        if not (expected / "Info.plist").is_file():
            raise RuntimeError("STOP: dependency archive is missing its xcframework")

        def inventory(path):
            return {str(p.relative_to(path)): sha256(p) for p in path.rglob("*")
                    if p.is_file() and not any(part.startswith("._") or part in (".DS_Store", "__MACOSX")
                                               for part in p.relative_to(path).parts)}

        if target.exists():
            if inventory(target) == inventory(expected):
                print("Verified the existing pinned GhosttyKit against its archive checksum.")
                return
            if not replace:
                raise RuntimeError("STOP: local GhosttyKit differs; use download-ghosttykit.sh --replace explicitly")
            shutil.rmtree(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(expected, target)
    print("Installed checksum-verified pinned GhosttyKit (no source build or host packages needed).")


def developer_environment():
    env = os.environ.copy()
    selected = env.get("DEVELOPER_DIR")
    if not selected:
        selected = output(["xcode-select", "--print-path"])
    if "CommandLineTools" in selected or not Path(selected).is_dir():
        candidates = list(Path("/Applications").glob("Xcode*.app/Contents/Developer"))
        if len(candidates) != 1:
            raise RuntimeError("Set DEVELOPER_DIR to a full Xcode installation")
        selected = str(candidates[0])
    env["DEVELOPER_DIR"] = selected
    toolchain = Path(selected) / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    env["PATH"] = str(toolchain) + os.pathsep + env.get("PATH", "")
    return env


def select_identity(requested=None, *, ad_hoc=False):
    if ad_hoc:
        return "-"
    identities = output(["security", "find-identity", "-v", "-p", "codesigning"])
    found = re.findall(r'([A-F0-9]{40}) "(Developer ID Application:[^"]+)"', identities)
    requested = requested or os.environ.get("SIGNING_IDENTITY")
    if requested:
        matches = [name for fingerprint, name in found if requested in (fingerprint, name)]
    else:
        matches = [name for _, name in found]
    if len(matches) != 1:
        raise RuntimeError("Select one valid Developer ID Application certificate with SIGNING_IDENTITY; "
                           "private keys are never exported. Use --ad-hoc only for a local build.")
    return matches[0]


def rpaths(binary):
    lines = output(["otool", "-l", binary]).splitlines()
    paths = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for item in lines[index + 1:index + 4]:
                if item.strip().startswith("path "):
                    paths.append(item.strip()[5:].rsplit(" (offset", 1)[0])
    return paths


def dependencies(binary):
    return [line.strip().split(" (compatibility", 1)[0]
            for line in output(["otool", "-L", binary]).splitlines()[1:] if line.strip()]


def system_path(value):
    return os.path.normpath(value).startswith(("/System/Library/", "/usr/lib/"))


def minimum_macos(binary):
    commands = output(["otool", "-l", binary])
    match = re.search(r"\bminos\s+([0-9.]+)", commands)
    if not match:
        match = re.search(r"LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+([0-9.]+)", commands)
    if not match:
        raise RuntimeError(f"STOP: cannot determine minimum macOS for {binary.name}")
    parts = [int(part) for part in match[1].split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def sign(path, identity, *, entitlements=None, runtime=False):
    args = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        args += ["--timestamp"]
        if runtime:
            args += ["--options", "runtime"]
    if entitlements:
        args += ["--entitlements", entitlements]
    run(args + [path])


def audit_bundle(app, *, require_developer_id=True):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": APP_NAME,
                "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise RuntimeError(f"STOP: invalid bundle metadata {key}")
    if "SUFeedURL" in info or "SUPublicEDKey" in info:
        raise RuntimeError("STOP: a self-updater feed/key remains in the release")
    for entry in app.rglob("*"):
        if entry.is_symlink() and not entry.resolve().is_relative_to(app.resolve()):
            raise RuntimeError("STOP: a bundled symlink points outside the app")
    resources = app / "Contents/Resources"
    for required in ("maquake.icns", "shell-integration/macuake.zsh",
                     "ThirdPartyNotices.txt", "KeyboardShortcuts_KeyboardShortcuts.bundle"):
        if not (resources / required).exists():
            raise RuntimeError(f"STOP: missing runtime resource {required}")
    executable = app / f"Contents/MacOS/{APP_NAME}"
    frameworks = app / "Contents/Frameworks"
    binaries = [executable] + list(frameworks.glob("*.dylib"))
    for binary in binaries:
        if output(["lipo", "-archs", binary]).split() != ["arm64"]:
            raise RuntimeError(f"STOP: unexpected release architecture in {binary.name}")
        if minimum_macos(binary) > (14, 0, 0):
            raise RuntimeError(f"STOP: {binary.name} requires a newer OS than advertised")
        for entry in rpaths(binary):
            if entry.startswith("/") and not system_path(entry):
                raise RuntimeError(f"STOP: nonportable loader path in {binary.name}: {entry}")
            if entry.startswith(("@loader_path", "@executable_path")):
                base = binary.parent if entry.startswith("@loader_path") else executable.parent
                suffix = entry.split("/", 1)[1] if "/" in entry else "."
                if not (base / suffix).resolve().is_relative_to(app.resolve()):
                    raise RuntimeError("STOP: loader path escapes the app")
        for linked in dependencies(binary):
            if "Sparkle" in linked:
                raise RuntimeError("STOP: Sparkle is still linked")
            if linked.startswith("/") and not system_path(linked):
                raise RuntimeError(f"STOP: non-system external dependency {linked}")
            if linked.startswith(("@loader_path/", "@executable_path/")):
                base = binary.parent if linked.startswith("@loader_path/") else executable.parent
                target = (base / linked.split("/", 1)[1]).resolve()
                if not target.is_relative_to(app.resolve()) or not target.exists():
                    raise RuntimeError(f"STOP: unresolved relative dependency {linked}")
            if linked.startswith("@rpath/"):
                relative = linked[len("@rpath/"):]
                if not (frameworks / relative).resolve().is_relative_to(app.resolve()):
                    raise RuntimeError("STOP: rpath dependency escapes the app")
                if not (frameworks / relative).exists() and not relative.startswith("libswift"):
                    raise RuntimeError(f"STOP: unresolved bundled dependency {linked}")
                if relative.startswith("libswiftCompatibility") and not (frameworks / relative).exists():
                    raise RuntimeError(f"STOP: missing Swift compatibility library {relative}")
    run(["codesign", "--verify", "--deep", "--strict", app])
    signature = run(["codesign", "--display", "--verbose=4", app], capture=True)
    details = signature.stdout + signature.stderr
    if require_developer_id and "Authority=Developer ID Application:" not in details:
        raise RuntimeError("STOP: publication requires a Developer ID Application signature")
    return info


def source_materials(destination, version):
    """Supply corresponding application/Ghostty/gettext sources alongside binaries."""
    ghostty = json.loads((ROOT / "Dependencies/GhosttyKit.json").read_text())
    gettext = json.loads((ROOT / "Dependencies/GettextSource.json").read_text())
    cache = ROOT / "build/dependencies"
    cache.mkdir(parents=True, exist_ok=True)
    gettext_archive = cache / "gettext-0.24.tar.gz"
    if not gettext_archive.exists() or sha256(gettext_archive) != gettext["sha256"]:
        run(["curl", "--fail", "--location", "--retry", "3", "--proto", "=https",
             "--proto-redir", "=https", "--output", gettext_archive, gettext["url"]])
    if sha256(gettext_archive) != gettext["sha256"]:
        raise RuntimeError("STOP: corresponding gettext source checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="sources-", dir=destination) as temporary:
        folder = Path(temporary) / "Macuake-source-materials"
        folder.mkdir()
        run(["git", "archive", "--format=tar.gz", "--output", folder / "macuake-source.tar.gz", "HEAD"])
        source = folder / "ghostty-source.tar.gz"
        url = f'https://github.com/ghostty-org/ghostty/archive/{ghostty["commit"]}.tar.gz'
        attempt = run(["curl", "--fail", "--location", "--retry", "3", "--proto", "=https",
                       "--proto-redir", "=https", "--output", source, url], check=False)
        if attempt.returncode:
            with source.open("wb") as stream:
                subprocess.run(["gh", "api", f'repos/ghostty-org/ghostty/tarball/{ghostty["commit"]}'],
                               cwd=ROOT, stdout=stream, check=True)
        # Verify that the supplied source archive is actually readable.
        with tarfile.open(source, "r:gz") as archive:
            if not any(member.name.endswith("/pkg/libintl/build.zig") for member in archive.getmembers()):
                raise RuntimeError("STOP: missing Ghostty gettext integration sources")
        shutil.copy2(gettext_archive, folder / gettext_archive.name)
        (folder / "README.md").write_text(
            f"# Macuake {version} source materials\n\n"
            "The app is MIT licensed; bundled components retain their own licenses.\n"
            "The accompanying app contains the LGPL GNU gettext runtime.\n"
            "This archive supplies the application source, pinned Ghostty integration source, "
            "and unmodified GNU gettext 0.24 source, including its license texts.\n\n"
            "Extract macuake-source.tar.gz and place the extracted Ghostty tree at vendor/ghostty.\n"
            "Follow scripts/build-ghostty.sh to rebuild the library, then use "
            "scripts/build-release.sh VERSION --ad-hoc --local-ghostty to relink the app.\n"
            "Build tools and remaining third-party sources are identified by the included "
            "Package.resolved and Ghostty build.zig.zon/pkg manifests.\n"
            "No private signing key is required for a locally rebuilt ad-hoc app.\n")
        run(["ditto", "-c", "-k", "--keepParent", folder, destination / SOURCE_NAME])
    return sha256(destination / SOURCE_NAME)


def build(version, *, identity=None, ad_hoc=False, local_ghostty=False):
    version = version_string(version)
    if sys.platform != "darwin":
        raise RuntimeError("Release builds require macOS and full Xcode")
    env = developer_environment()
    identity = select_identity(identity, ad_hoc=ad_hoc)
    if not ad_hoc and output(["git", "status", "--porcelain"]):
        raise RuntimeError("STOP: a signed release requires committed source")
    if local_ghostty and not ad_hoc:
        raise RuntimeError("Use --ad-hoc with --local-ghostty; publication always verifies the pinned binary")
    if not local_ghostty:
        dependency()
    locked = (ROOT / "Package.resolved").read_bytes()
    scratch = ROOT / ".build/release-arm64"
    flags = ["--scratch-path", scratch, "--build-system", "xcode", "--arch", "arm64",
             "--configuration", "release", "--disable-automatic-resolution"]
    run(["swift", "build"] + flags, env=env)
    bin_dir = Path(output(["swift", "build"] + flags + ["--show-bin-path"], env=env).splitlines()[-1])
    if (ROOT / "Package.resolved").read_bytes() != locked:
        raise RuntimeError("STOP: the release build changed dependency pins")
    source = output(["git", "rev-parse", "HEAD"])
    destination = ROOT / "build/releases" / version
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="package-", dir=destination) as folder:
        folder = Path(folder)
        app = folder / f"{APP_NAME}.app"
        executable = app / f"Contents/MacOS/{APP_NAME}"
        resources = app / "Contents/Resources"
        frameworks = app / "Contents/Frameworks"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        frameworks.mkdir(parents=True)
        shutil.copy2(bin_dir / APP_NAME, executable)
        executable.chmod(0o755)
        info = plistlib.loads((ROOT / "MaQuake/Resources/Info.plist").read_bytes())
        info.update({"CFBundleShortVersionString": version, "CFBundleVersion": version,
                     "MacuakeSourceRevision": source})
        info.pop("SUFeedURL", None)
        info.pop("SUPublicEDKey", None)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        for name in ("maquake.icns", "maquake-icon.png"):
            shutil.copy2(ROOT / "MaQuake/Resources" / name, resources / name)
        shutil.copytree(ROOT / "MaQuake/Resources/shell-integration", resources / "shell-integration")
        for bundle in bin_dir.glob("*.bundle"):
            if "Tests" not in bundle.name:
                shutil.copytree(bundle, resources / bundle.name, symlinks=True)
        notices = ["Macuake fork source: https://github.com/ldelossa/macuake\n"]
        notices.append((ROOT / "LICENSE").read_text())
        notices.append("\n--- Ghostty ---\n" + (ROOT / "Dependencies/Ghostty-LICENSE").read_text())
        for notice in sorted((ROOT / "Dependencies/Licenses").glob("*.txt")):
            notices.append("\n--- " + notice.stem + " ---\n" + notice.read_text())
        for package in sorted((scratch / "checkouts").glob("*")):
            for name in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"):
                license_file = package / name
                if license_file.is_file():
                    notices.append(f"\n\n--- {package.name} ---\n" + license_file.read_text(errors="replace"))
                    break
            for name in ("NOTICE", "NOTICE.txt"):
                if (package / name).is_file():
                    notices.append((package / name).read_text(errors="replace"))
        (resources / "ThirdPartyNotices.txt").write_text("\n".join(notices))
        run(["xcrun", "swift-stdlib-tool", "--copy", "--scan-executable", executable,
             "--platform", "macosx", "--destination", frameworks], env=env)
        binaries = [executable] + list(frameworks.glob("*.dylib"))
        for binary in binaries:
            archs = output(["lipo", "-archs", binary]).split()
            if archs != ["arm64"]:
                thin = binary.with_name(binary.name + ".arm64")
                run(["lipo", binary, "-thin", "arm64", "-output", thin])
                thin.replace(binary)
            for entry in rpaths(binary):
                if entry.startswith("/") and not system_path(entry):
                    run(["install_name_tool", "-delete_rpath", entry, binary])
        if "@executable_path/../Frameworks" not in rpaths(executable):
            run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", executable])
        for library in frameworks.glob("*.dylib"):
            sign(library, identity, runtime=True)
        for bundle in resources.glob("*.bundle"):
            sign(bundle, identity)
        sign(app, identity, entitlements=ROOT / "MaQuake/Resources/MaQuake.entitlements", runtime=True)
        audit_bundle(app, require_developer_id=not ad_hoc)
        assessment = run(["spctl", "--assess", "--type", "execute", "--verbose=4", app], capture=True, check=False)
        assessment_text = (assessment.stdout + assessment.stderr).strip()
        if not ad_hoc and assessment.returncode and "Unnotarized Developer ID" not in assessment_text:
            raise RuntimeError("STOP: unexpected Gatekeeper assessment: " + assessment_text)
        print("Gatekeeper assessment (not notarized by choice): " + assessment_text)
        archive = destination / ARCHIVE_NAME
        temporary_archive = folder / ARCHIVE_NAME
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, temporary_archive])
        temporary_archive.replace(archive)
        with tempfile.TemporaryDirectory(prefix="relocated-", dir=destination) as extracted:
            run(["ditto", "-x", "-k", archive, extracted])
            audit_bundle(Path(extracted) / f"{APP_NAME}.app", require_developer_id=not ad_hoc)
    digest = sha256(archive)
    checksums = f"{digest}  {ARCHIVE_NAME}\n"
    sources_digest = None if ad_hoc else source_materials(destination, version)
    if sources_digest:
        checksums += f"{sources_digest}  {SOURCE_NAME}\n"
    (destination / "SHA256SUMS").write_text(checksums)
    metadata = {"version": version, "source_commit": source, "repository": APP_REPO,
                "architecture": "arm64", "minimum_macos": "14.0", "bundle_id": BUNDLE_ID,
                "sha256": digest, "source_materials_sha256": sources_digest,
                "signing_identity": identity, "notarized": False,
                "xcode": output(["xcodebuild", "-version"], env=env)}
    (destination / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Verified release archive: {archive}\nSHA256: {digest}")
    return destination, metadata


def render_cask(version, digest):
    version = version_string(version)
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("A complete SHA256 is required")
    return f'''cask "macuake" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/{APP_REPO}/releases/download/v#{{version}}/{ARCHIVE_NAME}"
  name "Macuake"
  desc "Personal fork of a drop-down terminal with custom tabs and pane controls"
  homepage "https://github.com/{APP_REPO}"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Macuake.app"

  caveats <<~EOS
    This personal fork is Developer-ID signed but is not notarized.
    If macOS blocks first launch, use System Settings > Privacy & Security > Open Anyway.
    This cask does not disable Gatekeeper or remove quarantine.

    Macuake.app replaces the upstream app; it is not a side-by-side installation.
    Quit Macuake and finish terminal work before upgrading.
  EOS
end
'''


def publish(version, tap, *, identity=None):
    version = version_string(version)
    tap = Path(tap).expanduser().resolve()
    source = clean_main(ROOT, APP_REPO)
    clean_main(tap, TAP_REPO)
    tag = "v" + version
    if output(["git", "ls-remote", "origin", "refs/tags/" + tag]):
        raise RuntimeError("STOP: this release tag already exists; never overwrite published versions")
    existing = run(["gh", "release", "view", tag, "--repo", APP_REPO], capture=True, check=False)
    if existing.returncode == 0 or "release not found" not in existing.stderr.lower():
        raise RuntimeError("STOP: release exists or its absence cannot be verified")
    destination, metadata = build(version, identity=identity)
    if clean_main(ROOT, APP_REPO) != source or metadata["source_commit"] != source:
        raise RuntimeError("STOP: source main changed while building")
    clean_main(tap, TAP_REPO)
    prospective_cask = destination / "Casks/macuake.rb"
    prospective_cask.parent.mkdir(parents=True, exist_ok=True)
    prospective_cask.write_text(render_cask(version, metadata["sha256"]))
    run(["ruby", "-c", prospective_cask])
    # Homebrew 7 accepts source files for style, but --cask requires a tap token.
    run(["brew", "style", prospective_cask], env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1"})
    notes = destination / "release-notes.md"
    notes.write_text(f"""Apple Silicon build of the ldelossa fork, from `{source}`.

Includes independent tab/bar colors and opacity, picker ownership fixes, native
pane keyboard/cursor focus, pane zoom and inline tab rename actions.

Install: `brew install --cask ldelossa/macuake/macuake`.
Updates are managed by Homebrew, not Sparkle or upstream feeds.
This app is Developer-ID signed but intentionally **not notarized**; macOS may
require System Settings > Privacy & Security > Open Anyway on your personal Mac.
The cask never disables Gatekeeper or removes quarantine.

macOS 14+ and Apple Silicon required. Custom Ghostty keybindings are documented
in the repository README; personal settings/configuration are not bundled.
""")
    run(["git", "tag", "-a", tag, "-m", f"Macuake fork {version}", source])
    run(["git", "push", "origin", "refs/tags/" + tag])
    run(["gh", "release", "create", tag, "--repo", APP_REPO, "--verify-tag", "--draft",
         "--title", f"Macuake {version} (ldelossa fork)", "--notes-file", notes,
         destination / ARCHIVE_NAME, destination / SOURCE_NAME,
         destination / "SHA256SUMS", destination / "release.json"])
    with tempfile.TemporaryDirectory(prefix="verify-upload-", dir=destination) as downloaded:
        run(["gh", "release", "download", tag, "--repo", APP_REPO, "--pattern", ARCHIVE_NAME,
             "--dir", downloaded])
        if sha256(Path(downloaded) / ARCHIVE_NAME) != metadata["sha256"]:
            raise RuntimeError("STOP: uploaded bytes differ; draft left intact for investigation")
    run(["gh", "release", "edit", tag, "--repo", APP_REPO, "--draft=false", "--latest"])
    clean_main(tap, TAP_REPO)
    cask = tap / "Casks/macuake.rb"
    cask.parent.mkdir(parents=True, exist_ok=True)
    cask.write_text(render_cask(version, metadata["sha256"]))
    run(["ruby", "-c", cask])
    run(["brew", "style", cask], env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1"})
    run(["git", "add", "--", "Casks/macuake.rb"], cwd=tap)
    run(["git", "diff", "--cached", "--check"], cwd=tap)
    run(["git", "commit", "-m", f"Update Macuake to {version}"], cwd=tap)
    run(["git", "push", "origin", "main"], cwd=tap)
    print(f"Published https://github.com/{APP_REPO}/releases/tag/{tag}")
    print("Install: brew install --cask ldelossa/macuake/macuake")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    fetch = commands.add_parser("dependency", help="Download/verify the pinned GhosttyKit without installing host packages")
    fetch.add_argument("--replace", action="store_true", help="Explicitly replace a differing generated xcframework")
    package = commands.add_parser("build", help="Build/sign/verify an arm64 archive without installation")
    package.add_argument("version", type=version_string)
    package.add_argument("--identity")
    package.add_argument("--ad-hoc", action="store_true", help="Local-only unsigned-identity build; never used by publish")
    package.add_argument("--local-ghostty", action="store_true", help="Relink an explicitly rebuilt local library (ad-hoc builds only)")
    release = commands.add_parser("publish", help="Publish from clean pushed main and update a clean tap checkout")
    release.add_argument("version", type=version_string)
    release.add_argument("--tap-path", required=True)
    release.add_argument("--identity")
    options = parser.parse_args()
    try:
        if options.command == "dependency":
            dependency(replace=options.replace)
        elif options.command == "build":
            build(options.version, identity=options.identity, ad_hoc=options.ad_hoc,
                  local_ghostty=options.local_ghostty)
        else:
            publish(options.version, options.tap_path, identity=options.identity)
    except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        if options.command == "publish":
            print("Publication stopped. Any created tag/draft/release is intentionally retained; "
                  "inspect it before retrying. No force push or destructive rollback was attempted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
