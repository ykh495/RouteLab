"""Packaging gates: source membership, required resources, and project identifiers.
These are not a substitute for an Xcode build.
"""
from pathlib import Path
import json
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class ProjectPackagingTests(unittest.TestCase):
    def test_every_swift_source_is_in_build_phase_once(self):
        text = (ROOT / 'RouteLab.xcodeproj/project.pbxproj').read_text()
        phase = re.search(r'isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);', text).group(1)
        for source in (ROOT / 'RouteLab').glob('*.swift'):
            file_id = re.findall(r'([A-F0-9]{24}) = \{ isa = PBXFileReference;[^\n]*path = "' + re.escape(source.name) + r'";', text)
            self.assertEqual(len(file_id), 1, source.name)
            build_id = re.findall(r'([A-F0-9]{24}) = \{ isa = PBXBuildFile; fileRef = ' + file_id[0] + ';', text)
            self.assertEqual(len(build_id), 1, source.name)
            self.assertEqual(phase.split(',').count(build_id[0]), 1, source.name)

    def test_project_ids_and_scheme(self):
        text = (ROOT / 'RouteLab.xcodeproj/project.pbxproj').read_text()
        definitions = re.findall(r'^\s*([A-F0-9]{24}) = \{', text, re.M)
        self.assertEqual(len(definitions), len(set(definitions)))
        references = set(re.findall(r'\b[A-F0-9]{24}\b', text))
        self.assertTrue(references <= set(definitions))
        ET.parse(ROOT / 'RouteLab.xcodeproj/xcshareddata/xcschemes/RouteLab.xcscheme')
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 17.0', text)

    def test_permissions_localization_and_assets(self):
        info = plistlib.loads((ROOT / 'RouteLab/Info.plist').read_bytes())
        self.assertIn('location', info['UIBackgroundModes'])
        self.assertEqual(set(info['CFBundleLocalizations']), {'en', 'zh-Hans'})
        self.assertEqual(set(info['NSLocationTemporaryUsageDescriptionDictionary']), {'TripRecordingEN', 'TripRecordingZH'})
        for language in ('en', 'zh-Hans'):
            strings = (ROOT / f'RouteLab/{language}.lproj/InfoPlist.strings').read_text()
            self.assertIn('NSFaceIDUsageDescription', strings)
            self.assertIn('NSLocationWhenInUseUsageDescription', strings)
        plistlib.loads((ROOT / 'RouteLab/PrivacyInfo.xcprivacy').read_bytes())
        for path in (ROOT / 'RouteLab/Assets.xcassets').rglob('Contents.json'):
            data = json.loads(path.read_text())
            for image in data.get('images', []):
                if 'filename' in image:
                    self.assertTrue((path.parent / image['filename']).is_file())
