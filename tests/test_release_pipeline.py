import hashlib
import importlib.util
import io
import json
import struct
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "release_integrity", ROOT / "packaging" / "release_integrity.py"
)
integrity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integrity)


def metadata(path: Path) -> dict:
    return {
        "file": path.name,
        "size": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


class ReleasePipelineTests(unittest.TestCase):
    commit = "1234567890ab" + "c" * 28

    def make_app(self, path: Path) -> None:
        payload = bytearray(512)
        offset = 32
        struct.pack_into("<I", payload, offset, integrity.APP_DESCRIPTION_MAGIC)
        struct.pack_into("<I", payload, offset + 4, 0)
        version = (ROOT / "VERSION").read_text().strip().encode()
        payload[offset + 16:offset + 16 + len(version)] = version
        project = b"tiny_touch_unified"
        payload[offset + 48:offset + 48 + len(project)] = project
        idf = b"v5.3.2"
        payload[offset + 112:offset + 112 + len(idf)] = idf
        payload[256:268] = self.commit[:12].encode()
        payload[300:300 + len(integrity.PRODUCT_MARKER)] = integrity.PRODUCT_MARKER
        path.write_bytes(payload)

    def make_cli(self, path: Path) -> None:
        with tarfile.open(path, "w:gz") as archive:
            for name, value in (
                ("tinytouch/tinytouch", b"executable"),
                ("tinytouch/_internal/runtime", b"runtime"),
            ):
                info = tarfile.TarInfo(name)
                info.size = len(value)
                info.mode = 0o755
                archive.addfile(info, io.BytesIO(value))

    def make_release(self, root: Path) -> None:
        version = (ROOT / "VERSION").read_text().strip()
        layouts = {}
        for kind, images in integrity.EXPECTED_IMAGES.items():
            directory = root / kind
            directory.mkdir(parents=True)
            entries = []
            for address, name in images.items():
                path = directory / name
                if address == 0x10000:
                    self.make_app(path)
                elif name == "ota_data_initial.bin":
                    path.write_bytes(b"ota" * 32)
                elif name == "partition-table.bin":
                    path.write_bytes(b"partition")
                else:
                    path.write_bytes(kind.encode() + name.encode())
                entries.append({"name": name, "address": address, **metadata(path)})
            full = directory / integrity.EXPECTED_FULL_IMAGES[kind]
            full.write_bytes(b"full" + kind.encode())
            layouts[kind] = {
                "version": version,
                "protocol": integrity.PROTOCOL,
                "secureVersion": integrity.SECURE_VERSION,
                "flashSize": "4MB",
                "eraseAll": False,
                "compress": False,
                "images": entries,
                "fullImage": metadata(full),
            }
            (directory / "manifest.json").write_text(json.dumps(layouts[kind]))
        factory_app = root / "factory" / "tiny_touch_unified.bin"
        (root / "tiny_touch_unified.bin").write_bytes(factory_app.read_bytes())
        cli = {}
        for key, name in (
            ("macos-arm64", "tinytouch-macos-arm64.tar.gz"),
            ("macos-x86_64", "tinytouch-macos-x86_64.tar.gz"),
        ):
            path = root / name
            self.make_cli(path)
            cli[key] = {**metadata(path), "format": "tar.gz"}
        manifest = {
            "product": integrity.PRODUCT_MARKER.decode(),
            "version": version,
            "build": self.commit[:12],
            "protocol": integrity.PROTOCOL,
            "secureVersion": integrity.SECURE_VERSION,
            "boards": ["esp32s3-super-mini", "seeed-xiao-esp32s3"],
            "firmware": layouts,
            "ota": metadata(root / "tiny_touch_unified.bin"),
            "cli": cli,
        }
        (root / "release-manifest.json").write_text(json.dumps(manifest))

    def test_finalizer_produces_complete_flat_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = root / "release"
            release.mkdir()
            self.make_release(release)
            output = root / "publish"
            subprocess.run(
                [
                    "python3", str(ROOT / "packaging" / "finalize-release.py"),
                    str(release), "--output", str(output), "--commit", self.commit,
                ],
                check=True,
            )
            integrity.validate_release(output, self.commit, flat=True)
            integrity.validate_checksums(output)
            self.assertTrue((output / "ota_data_initial.bin").is_file())
            self.assertFalse((output / "ota_slot1.bin").exists())
            self.assertFalse((output / "tinytouch-web-flashers.tar.gz").exists())

            public = root / "public"
            public.mkdir()
            subprocess.run(
                [
                    "python3", str(ROOT / "packaging" / "sync-docs-release.py"),
                    str(output), str(public), "--commit", self.commit,
                ],
                check=True,
            )
            release_manifest = json.loads((output / "release-manifest.json").read_text())
            self.assertEqual(
                json.loads((public / "flash" / "factory" / "manifest.json").read_text()),
                release_manifest["firmware"]["factory"],
            )
            self.assertEqual(
                json.loads((public / "release.json").read_text()), release_manifest
            )
            self.assertTrue((public / "flash" / "recovery" / "manifest.json").is_file())
            self.assertEqual(
                json.loads((public / "flash" / "recovery" / "manifest.json").read_text()),
                release_manifest["firmware"]["factory"],
            )
            self.assertTrue((public / "cli" / "tinytouch-macos-arm64.tar.gz").is_file())
            (output / "unexpected.bin").write_bytes(b"unexpected")
            with self.assertRaisesRegex(integrity.IntegrityError, "published asset set mismatch"):
                integrity.validate_release(output, self.commit, flat=True)

    def test_descriptor_version_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_release(root)
            path = root / "factory" / "tiny_touch_unified.bin"
            data = bytearray(path.read_bytes())
            offset = data.find(struct.pack("<I", integrity.APP_DESCRIPTION_MAGIC))
            data[offset + 16:offset + 48] = b"stale\0" + b"\0" * 26
            path.write_bytes(data)
            manifest_path = root / "release-manifest.json"
            manifest = json.loads(manifest_path.read_text())
            image = manifest["firmware"]["factory"]["images"][2]
            image.update(metadata(path))
            (root / "tiny_touch_unified.bin").write_bytes(path.read_bytes())
            manifest["ota"].update(metadata(root / "tiny_touch_unified.bin"))
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(integrity.IntegrityError, "embedded version mismatch"):
                integrity.validate_release(root, self.commit)

    def test_candidate_extraction_rejects_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "candidate.tar.gz"
            with tarfile.open(archive_path, "w:gz") as archive:
                info = tarfile.TarInfo("publish/link")
                info.type = tarfile.SYMTYPE
                info.linkname = "../../outside"
                archive.addfile(info)
            with self.assertRaisesRegex(integrity.IntegrityError, "links are not allowed"):
                integrity.safe_extract(archive_path, root / "output")

    def test_checksum_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "firmware.tar.gz").write_bytes(b"firmware")
            (root / "checksums.txt").write_text(f"{'0' * 64}  firmware.tar.gz\n")
            with self.assertRaisesRegex(integrity.IntegrityError, "checksum mismatch"):
                integrity.validate_checksums(root)

    def test_app_firmware_channel_has_valid_exclusive_ranges(self):
        channel = integrity.validate_channel(ROOT / "channels" / "app-firmware.json")
        self.assertEqual(channel["releases"][0]["maxAppVersionExclusive"], "2.0.0")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "channel.json"
            broken = dict(channel)
            broken["releases"] = [dict(channel["releases"][0])]
            broken["releases"][0]["maxAppVersionExclusive"] = "1.0.0"
            path.write_text(json.dumps(broken))
            with self.assertRaisesRegex(integrity.IntegrityError, "empty app compatibility range"):
                integrity.validate_channel(path)

    def test_build_tag_and_release_workflow_contract(self):
        workflows = ROOT / ".github" / "workflows"
        build = (workflows / "firmware-build.yml").read_text()
        tag = (workflows / "firmware-tag.yml").read_text()
        release = (workflows / "firmware-release.yml").read_text()

        self.assertIn("pull_request:", build)
        self.assertIn("workflow_dispatch:", build)
        self.assertIn("workflow_call:", build)
        self.assertIn("contents: read", build)
        self.assertIn("espressif/idf:release-v5.3@sha256:", build)
        self.assertIn('safe.directory "$GITHUB_WORKSPACE"', build)
        self.assertIn("generate_signing_key", build)
        self.assertIn("TINYTOUCH_FIRMWARE_SIGNING_KEY_B64 is required", build)
        self.assertIn("must contain only the Base64-encoded PEM key", build)
        self.assertIn("Decoded firmware signing secret is not a PEM private key", build)
        self.assertIn("packaging/assemble-release.py", build)
        self.assertIn("packaging/release_integrity.py firmware", build)
        self.assertIn("packaging/release_integrity.py channel", build)
        self.assertIn('tinytouch-firmware-${version}.tar.gz', build)
        self.assertIn('sha256sum "$bundle"', build)

        self.assertEqual(tag.count("workflow_dispatch:"), 1)
        self.assertNotIn("pull_request:", tag)
        self.assertIn("actions: write", tag)
        self.assertIn("contents: write", tag)
        self.assertIn("CreateCommitOnBranchInput", tag)
        self.assertIn("createCommitOnBranch", tag)
        self.assertIn("expectedHeadOid", tag)
        self.assertIn("head_verified", tag)
        self.assertIn('.github/release-source.json', tag)
        self.assertIn('channels/app-firmware.json', tag)
        self.assertIn('if tag_ref="$(gh api', tag)
        self.assertNotIn('.object.sha 2>/dev/null || true', tag)
        self.assertIn("verification.verified", tag)
        self.assertIn("Tag $tag already", tag)
        self.assertIn("master changed before", tag)
        self.assertIn('-f ref="refs/tags/$tag" -f sha="$commit"', tag)
        self.assertIn("actions/workflows/firmware-release.yml/dispatches", tag)
        self.assertIn("-rc\\.", tag)

        self.assertIn('tags: ["v*"]', release)
        self.assertIn("workflow_dispatch:", release)
        self.assertIn("contents: write", release)
        self.assertIn("uses: ./.github/workflows/firmware-build.yml", release)
        self.assertIn("production: true", release)
        self.assertIn("secrets: inherit", release)
        self.assertIn('git show "$commit:VERSION"', release)
        self.assertIn("sha256sum --check --strict", release)
        self.assertIn("gh release create", release)
        self.assertIn('"dist/release/release-manifest.json"', release)
        self.assertIn('"dist/release/tiny_touch_unified.bin"', release)
        self.assertIn('"dist/release/factory/tiny_touch_factory_full.bin"', release)
        self.assertIn('--repo "$GITHUB_REPOSITORY"', release)
        self.assertIn("--generate-notes", release)
        self.assertNotIn("idf.py", release)
        self.assertNotIn("release-candidate", build + tag + release)

        self.assertFalse((workflows / "release-candidate.yml").exists())
        tag_release = (ROOT / "packaging" / "tag-release").read_text()
        self.assertNotIn("release-candidate", tag_release)
        self.assertIn('--ref master', tag_release)
        self.assertIn('${current##*.} + 1', tag_release)
        self.assertIn("exec packaging/tag-release", (ROOT / "packaging" / "release").read_text())

    def test_app_build_tag_and_release_workflow_contract(self):
        workflows = ROOT / ".github" / "workflows"
        build = (workflows / "app-build.yml").read_text()
        tag = (workflows / "app-tag.yml").read_text()
        release = (workflows / "app-release.yml").read_text()

        self.assertIn("pull_request:", build)
        self.assertIn("workflow_dispatch:", build)
        self.assertIn("workflow_call:", build)
        self.assertIn("swift test", build)
        self.assertIn("xcodebuild", build)
        self.assertIn("actions/upload-artifact@", build)
        self.assertEqual(tag.count("workflow_dispatch:"), 1)
        self.assertIn('tag="app-v$VERSION"', tag)
        self.assertIn("MARKETING_VERSION", tag)
        self.assertIn("CreateCommitOnBranchInput", tag)
        self.assertIn("actions/workflows/app-release.yml/dispatches", tag)
        self.assertIn('tags: ["app-v*"]', release)
        self.assertIn("uses: ./.github/workflows/app-build.yml", release)
        self.assertIn("actions/download-artifact@", release)
        self.assertIn("gh release create", release)
        self.assertIn("verification.verified", tag)
        self.assertIn("CFBundleShortVersionString", build)
        settings = (ROOT / "app" / "TinyTouch" / "DeviceManagementViews.swift").read_text()
        self.assertIn('LabeledContent("Version", value: version)', settings)
        project = (ROOT / "app" / "TinyTouch.xcodeproj" / "project.pbxproj").read_text()
        self.assertIn("objectVersion = 77;", project)

if __name__ == "__main__":
    unittest.main()
