"""Release staging must reject archive paths and symlinks that escape the app."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location(
    "prepare_update", Path(__file__).resolve().parents[2] / "scripts/prepare-update.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdateArchiveTests(unittest.TestCase):
    def check(self, name, target=None):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "update.zip"
            with zipfile.ZipFile(path, "w") as archive:
                if target is None:
                    archive.writestr(name, "synthetic")
                else:
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = 0o120777 << 16
                    archive.writestr(entry, target)
            module.check_zip(path)

    def test_rejects_path_traversal(self):
        for name in ("/outside", "../outside", "App.app/../../outside"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.check(name)

    def test_rejects_escaping_symlinks(self):
        for target in ("/outside", "../../outside"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.check("App.app/alias", target)

    def test_accepts_framework_layout(self):
        self.check("App.app/Contents/Frameworks/Sparkle.framework/Versions/Current", "B")
        self.check("App.app/Contents/Frameworks/Sparkle.framework/Sparkle", "Versions/Current/Sparkle")
        self.check("App.app/Contents/Info.plist")


if __name__ == "__main__":
    unittest.main()
