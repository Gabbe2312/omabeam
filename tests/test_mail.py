"""Tests for the mail helper's classification and parsing.

Run from the repository root:  python3 -m unittest discover tests
The helper is a script, not a module, so it is loaded by path.
"""

import email.header
import importlib.machinery
import importlib.util
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("omabeam_mail", str(HERE.parent / "bin" / "omabeam-mail"))
spec = importlib.util.spec_from_loader("omabeam_mail", loader)
mail = importlib.util.module_from_spec(spec)
loader.exec_module(mail)


class ClassifyTest(unittest.TestCase):
    def test_categories(self):
        cases = [
            ("Please verify your email address", False, "account"),
            ("Ordrebekreftelse 123", False, "receipt"),
            ("Security alert", False, "alert"),
            ("Your Steam account: Access from new computer", False, "alert"),
            ("Ihre Bestellung 555", False, "receipt"),
            ("Ukens tilbud", True, "newsletter"),
            ("Something entirely unrelated", False, "other"),
        ]
        for subject, unsubscribe, expected in cases:
            with self.subTest(subject=subject):
                self.assertEqual(mail.classify(subject, unsubscribe), expected)

    def test_verify_words(self):
        for subject in ["Bekreft e-postadressen din", "Confirm your email", "Set your password", "Verifiser kontoen"]:
            self.assertTrue(mail.VERIFY_RE.search(subject), subject)
        for subject in ["Welcome to Notion", "Your receipt", "Weekly digest"]:
            self.assertFalse(mail.VERIFY_RE.search(subject), subject)


class IdentityTest(unittest.TestCase):
    def test_google_grant_in_subject(self):
        for subject, app in [
            ("Strava was granted access to your Google Account", "Strava"),
            ("Vipps har fått tilgang til Google-kontoen din", "Vipps"),
        ]:
            raw = ("From: Google <no-reply@accounts.google.com>\r\nSubject: %s\r\n\r\n" % subject).encode()
            msg = email.message_from_bytes(raw)
            self.assertEqual(mail.detect_identity(msg, [""]), ("google", app))

    def test_apple_relay(self):
        raw = b"From: Adobe <no-reply@adobe.com>\r\nTo: k9x7@privaterelay.appleid.com\r\nSubject: Renewal\r\n\r\n"
        msg = email.message_from_bytes(raw)
        self.assertEqual(mail.detect_identity(msg, ["k9x7@privaterelay.appleid.com"]), ("apple", None))

    def test_google_app_in_body(self):
        html = b"Content-Type: text/html; charset=utf-8\r\n\r\n<table><tr><td>Ireland</td></tr><tr><td>Clipchamp was granted access to your Google Account</td></tr></table>"
        self.assertEqual(mail.google_apps_in_body(mail.body_text(html)), ["Clipchamp"])

    def test_welcome_mentions_provider(self):
        self.assertEqual(mail.provider_in_welcome("Welcome! You signed up with Google."), "google")
        self.assertEqual(mail.provider_in_welcome("Thanks for signing up using your Apple ID"), "apple")
        self.assertEqual(mail.provider_in_welcome("Download our app on Google Play today"), "")


class FoldTest(unittest.TestCase):
    def test_people_are_left_out_and_services_kept(self):
        cache = mail.empty_cache("me@gmail.com")
        now = time.time()
        mail.fold_message(cache, "me@gmail.com", b"From: Ola Nordmann <ola@gmail.com>\r\nSubject: Hei\r\nDate: Mon, 01 Sep 2025 10:00:00 +0000\r\n\r\n", now)
        mail.fold_message(cache, "me@gmail.com", b"From: GitHub <noreply@github.com>\r\nSubject: Verify your email\r\nDate: Mon, 01 Sep 2025 10:00:00 +0000\r\n\r\n", now)
        self.assertEqual(cache["people"], 1)
        self.assertIn("github.com", cache["senders"])
        self.assertTrue(cache["senders"]["github.com"]["verified"])

    def test_probably_rule(self):
        cache = mail.empty_cache("me@gmail.com")
        now = time.time()
        # a customer relationship with no confirmation mail ever: probably Google
        mail.fold_message(cache, "me@gmail.com", b"From: Notion <team@notion.so>\r\nSubject: Your receipt\r\nDate: Mon, 01 Sep 2025 10:00:00 +0000\r\n\r\n", now)
        # one that did ask for confirmation: its own login
        mail.fold_message(cache, "me@gmail.com", b"From: Komplett <no-reply@komplett.no>\r\nSubject: Bekreft e-postadressen din\r\nDate: Mon, 01 Sep 2025 10:00:00 +0000\r\n\r\n", now)
        services, _ = mail.footprint_account(cache, {})
        by_name = {s["name"]: s for s in services}
        self.assertEqual(by_name["Notion"]["identity"], "probably-google")
        self.assertEqual(by_name["Komplett"]["identity"], "")


class ImportTest(unittest.TestCase):
    def test_pasted_pages(self):
        google = "Third-party apps & services\nSpotify\nHas access to Google Account\nStrava\nLast used: 3 days ago\nZoom Workplace\nSee details\nRemove access"
        self.assertEqual(mail.parse_pasted(google), ["Spotify", "Strava", "Zoom Workplace"])
        apple = "Sign in with Apple\nApps using Apple ID\nDuolingo\nKayak\nStop using Apple ID"
        self.assertEqual(mail.parse_pasted(apple), ["Duolingo", "Kayak"])

    def test_domains(self):
        self.assertEqual(mail.base_domain("em.finn.no"), "finn.no")
        self.assertEqual(mail.base_domain("mail.bbc.co.uk"), "bbc.co.uk")
        self.assertEqual(mail.normalise_name("Zoom Workplace"), "zoomworkplace")


if __name__ == "__main__":
    unittest.main()
