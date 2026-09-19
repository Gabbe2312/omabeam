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



class ReadCapped(unittest.TestCase):
    def test_small_body_is_returned_whole(self):
        import io
        self.assertEqual(mail.read_capped(io.BytesIO(b"x" * 1000), 4096), b"x" * 1000)

    def test_oversized_body_is_refused(self):
        import io
        with self.assertRaises(ValueError):
            mail.read_capped(io.BytesIO(b"x" * 200000), 4096)


class FakeClient:
    """Answers a FETCH the way a server that ignores the byte range would."""

    def __init__(self, header):
        self.header = header
        self.items = []

    def uid(self, command, uids, item):
        self.items.append(item)
        return "OK", [(b"%d (UID %s BODY[HEADER.FIELDS (FROM)]<0> {%d}" % (i, u.encode(), len(self.header)), self.header)
                      for i, u in enumerate(uids.split(","), 1)]


class BoundedMail(unittest.TestCase):
    def test_headers_are_asked_for_with_a_byte_range(self):
        client = FakeClient(b"From: a@example.com\r\n\r\n")
        mail.fetch_headers(client, [1, 2])
        self.assertIn("<0.%d>" % mail.HEADER_BYTES, client.items[0])

    def test_oversized_header_is_cut_before_parsing(self):
        huge = b"From: shop@example.com\r\nSubject: " + b"x" * 500000 + b"\r\n\r\n"
        got = mail.fetch_headers(FakeClient(huge), [7])
        self.assertEqual(len(got[7]), mail.HEADER_BYTES)
        self.assertEqual(email.message_from_bytes(got[7])["From"], "shop@example.com")

    def test_bodies_go_out_in_small_batches(self):
        client = FakeClient(b"x")
        mail.fetch_bodies(client, range(1, mail.BODY_BATCH * 2 + 2))
        self.assertEqual(len(client.items), 3)

    def test_batch_bounds_are_what_the_comment_says(self):
        self.assertLessEqual(mail.BATCH * mail.HEADER_BYTES, mail.COMMAND_MAX_BYTES)
        self.assertLessEqual(mail.BODY_BATCH * mail.BODY_BYTES, mail.COMMAND_MAX_BYTES)
        self.assertLessEqual(mail.BODY_BYTES, mail.LITERAL_MAX_BYTES)

    def test_oversized_literal_is_refused_unread(self):
        class Base:
            def __init__(self): self.reads = []
            def read(self, size): self.reads.append(size); return b""
            def shutdown(self): self.closed = True
        class Client(mail._Bounded, Base):
            pass
        client = Client()
        client.begin()
        client.read(1000)
        with self.assertRaises(mail.imaplib.IMAP4.abort):
            client.read(mail.LITERAL_MAX_BYTES + 1)
        self.assertEqual(client.reads, [1000])
        self.assertTrue(client.closed)

    def test_many_literals_run_out_of_budget(self):
        class Base:
            def read(self, size): return b""
            def shutdown(self): pass
        class Client(mail._Bounded, Base):
            pass
        client = Client()
        client.begin()
        with self.assertRaises(mail.imaplib.IMAP4.abort):
            for _ in range(mail.COMMAND_MAX_BYTES // mail.LITERAL_MAX_BYTES + 1):
                client.read(mail.LITERAL_MAX_BYTES)

if __name__ == "__main__":
    unittest.main()
