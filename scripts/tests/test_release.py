import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("macuake_release", Path(__file__).resolve().parents[1] / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleasePolicyTests(unittest.TestCase):
    def test_versions_are_safe_path_and_tag_components(self):
        self.assertEqual(release.version_string("0.3.2"), "0.3.2")
        for value in ("../0.3.2", "v0.3.2", "0.3.2;echo bad", "0.3.2\n", "0.3", ""):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.version_string(value)

    def test_only_exact_fork_remotes_match(self):
        self.assertTrue(release.remote_matches("git@github.com:ldelossa/macuake.git", release.APP_REPO))
        self.assertTrue(release.remote_matches("https://github.com/ldelossa/macuake.git", release.APP_REPO))
        for url in ("git@github.com:menemy/macuake.git", "https://github.com.evil.invalid/ldelossa/macuake",
                    "https://user:example@github.com/ldelossa/macuake.git"):
            self.assertFalse(release.remote_matches(url, release.APP_REPO))

    def test_cask_is_checksum_pinned_arm64_and_homebrew_managed(self):
        cask = release.render_cask("0.3.2", "a" * 64)
        for expected in ('version "0.3.2"', 'sha256 "' + "a" * 64 + '"',
                         'https://github.com/ldelossa/macuake/releases/download/v#{version}/Macuake-arm64.zip',
                         'depends_on arch: :arm64', 'depends_on macos: :sonoma',
                         'app "Macuake.app"', "not notarized", "Open Anyway"):
            self.assertIn(expected, cask)
        for forbidden in ("auto_updates", "zap ", "xattr", "spctl", "menemy", "latest/download"):
            self.assertNotIn(forbidden, cask)
        with self.assertRaises(ValueError):
            release.render_cask("0.3.2", "incomplete")

    def test_dependency_manifest_is_exact_and_not_ambient_repository(self):
        manifest = json.loads((release.ROOT / "Dependencies/GhosttyKit.json").read_text())
        self.assertEqual(manifest["commit"], "332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28")
        self.assertEqual(manifest["repository"], "menemy/macuake")
        self.assertRegex(manifest["sha256"], r"^[a-f0-9]{64}$")
        self.assertEqual(manifest["tag"], "ghosttykit-" + manifest["commit"])

    def test_identity_selection_never_uses_development_or_ad_hoc_for_publication(self):
        identity = 'Developer ID Application: Example Contributor (EXAMPLE123)'
        listing = '  1) ' + 'A' * 40 + ' "' + identity + '"\n'
        with patch.object(release, "output", return_value=listing), patch.dict("os.environ", {}, clear=True):
            self.assertEqual(release.select_identity(), identity)
            self.assertEqual(release.select_identity("A" * 40), identity)
            with self.assertRaises(RuntimeError):
                release.select_identity("-")
        with patch.object(release, "output", return_value=' 1) "Apple Development: Example"'):
            with self.assertRaises(RuntimeError):
                release.select_identity()
        self.assertEqual(release.select_identity(ad_hoc=True), "-")

    def test_system_paths_cannot_escape_through_parent_components(self):
        self.assertTrue(release.system_path("/usr/lib/libSystem.B.dylib"))
        self.assertFalse(release.system_path("/usr/lib/../../tmp/private.dylib"))
        self.assertFalse(release.system_path("/opt/homebrew/lib/example.dylib"))

    def test_loader_and_os_version_parsers(self):
        commands = "cmd LC_RPATH\n cmdsize 48\n path @executable_path/../Frameworks (offset 12)\n" \
                   "cmd LC_BUILD_VERSION\n minos 14.0\n sdk 27.0\n"
        with patch.object(release, "output", return_value=commands):
            self.assertEqual(release.rpaths(Path("Example")), ["@executable_path/../Frameworks"])
            self.assertEqual(release.minimum_macos(Path("Example")), (14, 0, 0))

    def test_sha256(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "data"
            path.write_bytes(b"abc")
            self.assertEqual(release.sha256(path), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


class DependencyArchiveTests(unittest.TestCase):
    def test_appledouble_metadata_does_not_replace_matching_framework(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            commit = "a" * 40
            cache = root / "build/dependencies"
            cache.mkdir(parents=True)
            archive = cache / (commit + ".tar.gz")
            with tarfile.open(archive, "w:gz") as package:
                for name, contents in (("Info.plist", b"fixture"), ("._Info.plist", b"AppleDouble"),
                                       ("macos/Headers/ghostty.h", b"header"),
                                       ("macos/Headers/._ghostty.h", b"AppleDouble")):
                    member = tarfile.TarInfo("GhosttyKit.xcframework/" + name)
                    member.size = len(contents)
                    package.addfile(member, io.BytesIO(contents))
            manifest = {"commit": commit, "sha256": release.sha256(archive)}
            (root / "Dependencies").mkdir()
            (root / "Dependencies/GhosttyKit.json").write_text(json.dumps(manifest))
            target = root / "vendor/ghostty/macos/GhosttyKit.xcframework"
            (target / "macos/Headers").mkdir(parents=True)
            (target / "Info.plist").write_bytes(b"fixture")
            header = target / "macos/Headers/ghostty.h"
            header.write_bytes(b"header")
            before = header.stat().st_mtime_ns
            with patch.object(release, "ROOT", root), \
                 patch.object(release, "output", return_value="160000 commit " + commit + " vendor/ghostty"):
                release.dependency()
                self.assertEqual(header.stat().st_mtime_ns, before)
                self.assertFalse((target / "._Info.plist").exists())
                header.write_bytes(b"local modification")
                with self.assertRaisesRegex(RuntimeError, "local GhosttyKit differs"):
                    release.dependency()
                self.assertEqual(header.read_bytes(), b"local modification")


class RepositoryGuardTests(unittest.TestCase):
    def test_clean_main_checks_fetch_push_head_and_root(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            replies = {
                ("git", "rev-parse", "--show-toplevel"): str(root),
                ("git", "remote", "get-url", "origin"): "git@github.com:ldelossa/macuake.git",
                ("git", "remote", "get-url", "--push", "--all", "origin"): "git@github.com:ldelossa/macuake.git",
                ("git", "branch", "--show-current"): "main",
                ("git", "status", "--porcelain"): "",
                ("git", "rev-parse", "HEAD"): "a" * 40,
                ("git", "ls-remote", "origin", "refs/heads/main"): "a" * 40 + "\trefs/heads/main",
            }
            with patch.object(release, "output", side_effect=lambda args, **_: replies[tuple(args)]):
                self.assertEqual(release.clean_main(root, release.APP_REPO), "a" * 40)
                for key, bad_value in (
                    (("git", "remote", "get-url", "--push", "--all", "origin"), "git@github.com:menemy/macuake.git"),
                    (("git", "branch", "--show-current"), "ui-updates"),
                    (("git", "status", "--porcelain"), " M README.md"),
                    (("git", "ls-remote", "origin", "refs/heads/main"), "b" * 40 + "\trefs/heads/main"),
                    (("git", "rev-parse", "--show-toplevel"), str(root.parent)),
                ):
                    original = replies[key]
                    replies[key] = bad_value
                    with self.subTest(key=key), self.assertRaises(RuntimeError):
                        release.clean_main(root, release.APP_REPO)
                    replies[key] = original


class BundleAuditTests(unittest.TestCase):
    def make_app(self, folder):
        app = Path(folder) / "Macuake.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/Frameworks").mkdir()
        (app / "Contents/MacOS/Macuake").write_bytes(b"fixture")
        for name in ("maquake.icns", "ThirdPartyNotices.txt", "KeyboardShortcuts_KeyboardShortcuts.bundle",
                     "shell-integration/macuake.zsh"):
            path = resources / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
        info = {"CFBundleIdentifier": "com.maquake.app", "CFBundleExecutable": "Macuake",
                "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        return app

    def test_missing_resources_and_external_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(folder)
            (app / "Contents/Resources/ThirdPartyNotices.txt").unlink()
            with self.assertRaisesRegex(RuntimeError, "missing runtime resource"):
                release.audit_bundle(app)
            (app / "Contents/Resources/external").symlink_to(Path(folder).parent)
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                release.audit_bundle(app)

    def test_nonportable_paths_newer_os_and_adhoc_signature_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(folder)
            signature = subprocess.CompletedProcess([], 0, stdout="", stderr="Authority=Developer ID Application: Example")
            with patch.object(release, "output", return_value="arm64"), \
                 patch.object(release, "rpaths", return_value=[]), \
                 patch.object(release, "dependencies", return_value=[]), \
                 patch.object(release, "minimum_macos", return_value=(14, 0, 0)), \
                 patch.object(release, "run", return_value=signature):
                release.audit_bundle(app)
                with patch.object(release, "rpaths", return_value=["/tmp/build/PackageFrameworks"]):
                    with self.assertRaisesRegex(RuntimeError, "nonportable"):
                        release.audit_bundle(app)
                with patch.object(release, "minimum_macos", return_value=(15, 0, 0)):
                    with self.assertRaisesRegex(RuntimeError, "newer OS"):
                        release.audit_bundle(app)
                with patch.object(release, "dependencies", return_value=["@rpath/libswiftCompatibilitySpan.dylib"]):
                    with self.assertRaisesRegex(RuntimeError, "missing Swift compatibility"):
                        release.audit_bundle(app)
                with patch.object(release, "run", return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="Signature=adhoc")):
                    with self.assertRaisesRegex(RuntimeError, "Developer ID"):
                        release.audit_bundle(app)


class PublisherTests(unittest.TestCase):
    def exercise(self, corrupt=False, bad_style=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        output = root / "output"
        output.mkdir()
        tap = root / "tap"
        tap.mkdir()
        payload = b"verified archive fixture"
        fixture = output / release.ARCHIVE_NAME
        fixture.write_bytes(payload)
        digest = release.sha256(fixture)
        metadata = {"source_commit": "a" * 40, "sha256": digest}
        commands = []

        def fake_run(args, **kwargs):
            args = list(map(str, args))
            commands.append(args)
            if args[:3] == ["gh", "release", "view"]:
                return subprocess.CompletedProcess(args, 1, stdout="", stderr="release not found")
            if bad_style and args[:2] == ["brew", "style"]:
                raise subprocess.CalledProcessError(1, args)
            if args[:3] == ["gh", "release", "download"]:
                destination = Path(args[args.index("--dir") + 1])
                (destination / release.ARCHIVE_NAME).write_bytes(b"corrupt" if corrupt else payload)
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(release, "clean_main", return_value="a" * 40), \
             patch.object(release, "output", return_value=""), \
             patch.object(release, "build", return_value=(output, metadata)), \
             patch.object(release, "run", side_effect=fake_run), \
             patch("builtins.print"):
            if corrupt or bad_style:
                with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                    release.publish("0.3.2", tap)
            else:
                release.publish("0.3.2", tap)
                self.assertIn(digest, (tap / "Casks/macuake.rb").read_text())
        return commands

    def test_publication_is_draft_then_verified_then_tap_push(self):
        commands = self.exercise()
        positions = {"draft": next(i for i, c in enumerate(commands) if c[:3] == ["gh", "release", "create"]),
                     "download": next(i for i, c in enumerate(commands) if c[:3] == ["gh", "release", "download"]),
                     "publish": next(i for i, c in enumerate(commands) if "--draft=false" in c),
                     "tap_commit": next(i for i, c in enumerate(commands) if c[:2] == ["git", "commit"])}
        self.assertLess(positions["draft"], positions["download"])
        self.assertLess(positions["download"], positions["publish"])
        self.assertLess(positions["publish"], positions["tap_commit"])
        for command in commands:
            self.assertNotIn("--force", command)
            if command[0] == "gh":
                self.assertEqual(command[command.index("--repo") + 1], "ldelossa/macuake")
        self.assertEqual(commands[-1], ["git", "push", "origin", "main"])

    def test_corrupt_upload_is_not_published_and_tap_is_not_committed(self):
        commands = self.exercise(corrupt=True)
        self.assertFalse(any("--draft=false" in command for command in commands))
        self.assertFalse(any(command[:2] == ["git", "commit"] for command in commands))

    def test_bad_cask_is_detected_before_any_tag_or_release_creation(self):
        commands = self.exercise(bad_style=True)
        self.assertFalse(any(command[:2] == ["git", "tag"] for command in commands))
        self.assertFalse(any(command[:3] == ["gh", "release", "create"] for command in commands))


if __name__ == "__main__":
    unittest.main()
