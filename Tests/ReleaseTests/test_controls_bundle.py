import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/controls-bundle.py'
spec = importlib.util.spec_from_file_location('controls_bundle', SCRIPT)
controls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controls)


class ControlsBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Dilated.app'
        self.extension = self.app / 'Contents/PlugIns/DilatedControls.appex'
        self.info = {'CFBundleIdentifier': 'com.codeswhat.dilated',
                     'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '17'}
        self.extension_info = dict(self.info, CFBundleIdentifier='com.codeswhat.dilated.controls',
                                   CFBundleExecutable='DilatedControls', LSMinimumSystemVersion='26.0',
                                   NSExtension={'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'})
        self.write_plist(self.app / 'Contents/Info.plist', self.info)
        self.write_plist(self.extension / 'Contents/Info.plist', self.extension_info)
        self.binary = self.extension / 'Contents/MacOS/DilatedControls'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(struct.pack('<IIIIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0))
        self.action = {'supportedModes': 2, 'isDiscoverable': False,
                       'systemProtocols': ['com.apple.link.systemProtocol.SetValue'],
                       'parameters': [{'name': 'value', 'isOptional': False,
                                       'valueType': {'primitive': {'wrapper': {'typeIdentifier': 1}}}}]}
        for bundle in (self.app, self.extension):
            self.write_actions(bundle, {'SetAwakeControlIntent': self.action})

    def write_plist(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def write_actions(self, bundle, actions):
        path = bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'actions': actions}))

    def test_valid_direct_and_mas_layouts(self):
        controls.validate(self.app)
        self.info['CFBundleIdentifier'] = 'com.codeswhat.dilated.appstore'
        self.extension_info['CFBundleIdentifier'] = 'com.codeswhat.dilated.appstore.controls'
        self.write_plist(self.app / 'Contents/Info.plist', self.info)
        self.write_plist(self.extension / 'Contents/Info.plist', self.extension_info)
        controls.validate(self.app)

    def test_missing_extension_or_extra_plugin_cannot_ship(self):
        self.binary.unlink()
        with self.assertRaisesRegex(ValueError, 'arm64'):
            controls.validate(self.app)
        (self.app / 'Contents/PlugIns/Unexpected.appex').mkdir()
        with self.assertRaisesRegex(ValueError, 'PlugIns'):
            controls.validate(self.app)

    def test_wrong_identity_or_version_cannot_ship(self):
        for key, value in [('CFBundleIdentifier', 'foreign.control'), ('CFBundleVersion', '16'),
                           ('CFBundleShortVersionString', '9.0'), ('LSMinimumSystemVersion', '27.0')]:
            with self.subTest(key=key):
                changed = dict(self.extension_info, **{key: value})
                self.write_plist(self.extension / 'Contents/Info.plist', changed)
                with self.assertRaises(ValueError):
                    controls.validate(self.app)

    def test_action_must_exist_in_both_targets_and_dispatch_to_host(self):
        for bundle in (self.app, self.extension):
            self.write_actions(bundle, {})
            with self.assertRaisesRegex(ValueError, 'intent'):
                controls.validate(self.app)
            self.write_actions(bundle, {'SetAwakeControlIntent': dict(self.action, supportedModes=1)})
            with self.assertRaisesRegex(ValueError, 'intent'):
                controls.validate(self.app)
            self.write_actions(bundle, {'SetAwakeControlIntent': self.action})

    def test_only_exact_group_and_sandbox_are_accepted(self):
        valid = {'com.apple.security.app-sandbox': True,
                 'com.apple.security.application-groups': [controls.APP_GROUP]}
        controls.validate_entitlements(valid)
        for changed in [dict(valid, **{'com.apple.security.app-sandbox': False}),
                        dict(valid, **{'com.apple.security.application-groups': ['foreign']}),
                        dict(valid, **{'com.apple.security.network.server': True})]:
            with self.assertRaises(ValueError):
                controls.validate_entitlements(changed)
