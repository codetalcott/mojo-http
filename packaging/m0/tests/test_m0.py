"""The verdicts no CI leg can reach by running on the machine they refuse.

`smoke-m0-wheel` runs this with the INSTALLED wheel's interpreter, so what
is imported is the wheel, not the tree. The refusals a machine CAN be put
into -- the wrong mojo, no cc, a foreign prefix -- are the smoke's own arms;
these are the rest: a platform nothing here runs on, a cc that cannot link,
gcc without the name cc, a doctor format from another m0, and the command
line's exit 2.
"""

import contextlib
import io
import json
import unittest

from m0 import build, checks, cli, doctor


class Platform(unittest.TestCase):
    def test_the_three_supported(self):
        for system, machine, libc in (
            ("darwin", "arm64", ""),
            ("linux", "x86_64", "glibc"),
            ("linux", "aarch64", "glibc"),
        ):
            self.assertTrue(checks.platform_verdict(system, machine, libc).ok)

    def test_refused_with_78_and_no_fix_offered(self):
        for system, machine, libc in (
            ("linux", "x86_64", "not-glibc"),
            ("darwin", "x86_64", ""),
            ("win32", "AMD64", ""),
            ("linux", "riscv64", "glibc"),
        ):
            got = checks.platform_verdict(system, machine, libc)
            self.assertFalse(got.ok)
            self.assertEqual(got.exit, 78)
            self.assertIn("no fix", got.fix)
            self.assertTrue(got.sentence().startswith("m0: Mojo has no toolchain for "))


class Compiler(unittest.TestCase):
    def test_gcc_without_the_name_cc_is_refused_and_says_so(self):
        got = checks.compiler_verdict("linux", True, None, "gcc", None, "FIX")
        self.assertFalse(got.ok)
        self.assertIn("named cc", got.detail)
        self.assertIn("gcc", got.fix)

    def test_a_cc_that_cannot_link_is_refused_with_its_own_words(self):
        got = checks.compiler_verdict(
            "linux", True, "/usr/bin/cc", None, "ld: cannot find crti.o", "FIX"
        )
        self.assertFalse(got.ok)
        self.assertIn("crti.o", got.detail)
        self.assertEqual(got.fix, "FIX")

    def test_macos_without_the_tools_never_reaches_cc(self):
        got = checks.compiler_verdict("darwin", False, "/usr/bin/cc", None, None, "")
        self.assertFalse(got.ok)
        self.assertEqual(got.fix, "xcode-select --install")

    def test_a_cc_that_links_passes(self):
        self.assertTrue(
            checks.compiler_verdict("linux", True, "/usr/bin/cc", None, None, "").ok
        )


class Pair(unittest.TestCase):
    def test_the_sentence(self):
        got = checks.gated_verdict("0.1.0", "1.2.0", ["1.1.0"])
        self.assertEqual(
            got.sentence(),
            "m0: m0 0.1.0 is gated on mojo 1.1.0 and this environment has "
            "mojo 1.2.0 (uv add --dev 'mojo==1.1.0')",
        )

    def test_equality_is_string_equality(self):
        self.assertFalse(checks.gated_verdict("0.1.0", "1.1.0.post1", ["1.1.0"]).ok)
        self.assertTrue(checks.gated_verdict("0.1.0", "1.1.0", ["1.1.0"]).ok)

    def test_a_foreign_prefix_is_asked_before_anything_else(self):
        got = checks.installed_verdict("/x", True, False, "1.1.0", True, ["1.1.0"])
        self.assertEqual(
            got.sentence(),
            "m0: this m0 runs from /x, not this project's .venv (uv run m0 <command>)",
        )


class TheList(unittest.TestCase):
    def test_order(self):
        self.assertEqual(
            [name for name, _ in checks.CHECKS],
            ["platform", "mojo-installed", "mojo-gated", "c-compiler", "project"],
        )


class Doctor(unittest.TestCase):
    def test_the_last_line_is_the_report(self):
        report, error = doctor.host_report('a banner\n{"m0_host":"1","ok":true}\n')
        self.assertEqual(report["ok"], True)
        self.assertIsNone(error)

    def test_another_format_is_refused_by_name(self):
        report, error = doctor.host_report('{"m0_host":"2","ok":true}\n')
        self.assertIsNone(report)
        self.assertEqual(
            error.sentence(),
            "m0: bin/server prints doctor format 2 and this m0 reads 1 (m0 build)",
        )

    def test_an_app_that_refused_before_serve_printed_no_report(self):
        self.assertEqual(doctor.host_report("app: X is not set\n"), (None, None))
        self.assertEqual(doctor.host_report('{"m0serve":"1.5.0"}\n'), (None, None))

    def test_exit_is_the_first_failed_check_then_the_app(self):
        ok = checks.Result("a", True, "")
        bad = checks.Result("b", False, "d", "f")
        self.assertEqual(doctor.exit_code([ok, bad], {"exit": 3}, None), 78)
        self.assertEqual(doctor.exit_code([ok], {"exit": 3}, None), 3)
        self.assertEqual(doctor.exit_code([ok], None, None), 0)
        self.assertEqual(json.dumps(bad.as_json()),
                         '{"name": "b", "ok": false, "detail": "d", "fix": "f", "exit": 78}')


class CommandLine(unittest.TestCase):
    def _exit(self, argv):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as caught:
            cli.main(argv)
        return caught.exception.code, err.getvalue()

    def test_release_native_is_2_and_names_the_baseline(self):
        code, said = self._exit(["build", "--release", "--target-cpu", "native"])
        self.assertEqual(code, 2)
        self.assertIn(build.baseline_cpu(), said)

    def test_the_set_is_closed(self):
        for argv in (["new", "x"], ["build", "-o", "x"], ["build", "--rel"],
                     ["test", "--", "x"], []):
            self.assertEqual(self._exit(argv)[0], 2, argv)

    def test_baselines_are_build_serves(self):
        self.assertEqual(build.baseline_cpu("darwin", "arm64"), "apple-m1")
        self.assertEqual(build.baseline_cpu("linux", "aarch64"), "generic")
        self.assertEqual(build.baseline_cpu("linux", "x86_64"), "x86-64-v2")


if __name__ == "__main__":
    unittest.main()
