#!/usr/bin/env python3
"""Structural regression tests for the TestFlight publishing script.

These intentionally avoid executing upload_and_attach_testflight.sh because the real
script archives/uploads to App Store Connect. They lock down the distribution-mode
contract and the App Store Connect API flow we depend on.
"""

from pathlib import Path
import re
import unittest


SCRIPT = Path(__file__).with_name("upload_and_attach_testflight.sh").read_text(encoding="utf-8")


class TestTestFlightPublishScript(unittest.TestCase):
    def test_internal_distribution_is_default_and_marks_upload_internal_only(self):
        self.assertIn('TESTFLIGHT_DISTRIBUTION="${TESTFLIGHT_DISTRIBUTION:-internal}"', SCRIPT)
        self.assertRegex(SCRIPT, r'TESTFLIGHT_DISTRIBUTION.*\^\(internal\|external\)\$')
        self.assertRegex(
            SCRIPT,
            r'(?s)if \[\[ "\$TESTFLIGHT_DISTRIBUTION" == "internal" \]\].*testFlightInternalTestingOnly.*<true/>',
            msg="internal uploads must keep using testFlightInternalTestingOnly=true",
        )

    def test_external_distribution_omits_internal_only_upload_flag(self):
        internal_only_key_count = SCRIPT.count("testFlightInternalTestingOnly")
        self.assertEqual(
            internal_only_key_count,
            1,
            "external path should omit the internal-only upload flag entirely; only the internal branch may contain it",
        )

    def test_external_distribution_submits_beta_app_review(self):
        self.assertIn('"$TESTFLIGHT_DISTRIBUTION"', SCRIPT)
        self.assertIn("betaAppReviewSubmissions", SCRIPT)
        self.assertRegex(
            SCRIPT,
            r'(?s)def submit_beta_app_review\(build_id\):.*POST.*betaAppReviewSubmissions',
            msg="script should create a beta app review submission for external builds",
        )
        self.assertRegex(
            SCRIPT,
            r'(?s)if distribution == "external":.*submit_beta_app_review\(build_id\)',
            msg="external builds should automatically submit beta app review after attaching to the group",
        )

    def test_script_does_not_trigger_optional_beta_build_notification(self):
        self.assertNotIn("buildBetaNotifications", SCRIPT)


if __name__ == "__main__":
    unittest.main()
