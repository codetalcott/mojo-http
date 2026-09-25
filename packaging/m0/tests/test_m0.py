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

import os
import tempfile
from pathlib import Path

import signal
import subprocess
import sys
import time

from m0 import build, checks, cli, dev, doctor, image, new, paths


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
            ["platform", "mojo-installed", "mojo-gated", "max-gated", "c-compiler", "project"],
        )


class MaxPair(unittest.TestCase):
    def test_absent_is_optional_and_names_the_way_in(self):
        got = checks.max_verdict("0.3.0", None, ["26.6.0"])
        self.assertTrue(got.ok)
        self.assertIn("not installed", got.detail)
        self.assertIn("uv add --dev 'max-core==26.6.0'", got.detail)

    def test_another_version_is_refused_with_the_sentence(self):
        got = checks.max_verdict("0.3.0", "26.7.0", ["26.6.0"])
        self.assertEqual(
            got.sentence(),
            "m0: m0 0.3.0 is gated beside max-core 26.6.0 and this environment has "
            "max-core 26.7.0 (uv add --dev 'max-core==26.6.0')",
        )
        self.assertEqual(got.exit, 78)

    def test_the_gated_version_passes_by_string_equality(self):
        self.assertTrue(checks.max_verdict("0.3.0", "26.6.0", ["26.6.0"]).ok)
        self.assertFalse(checks.max_verdict("0.3.0", "26.6.0.post1", ["26.6.0"]).ok)


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
        # `dev` and `image` exist since 0.1.0's third pull request; what is
        # closed about them is everything that is not theirs: a host flag
        # without the `--` that hands it over, a deploy, a push, a port.
        for argv in (["dev", "--port", "8080"], ["dev", "--watch", "x"],
                     ["image", "--push"], ["image", "--deploy"], ["image", "x"],
                     ["deploy"], ["watch"],
                     ["new", "x", "--ui", "htmx"],
                     ["new", "x", "--template", "auth"], ["new", "x", "--live"],
                     ["build", "-o", "x"], ["build", "--rel"],
                     ["build", "--", "x"], ["include", "--", "x"],
                     ["test", "--", "x"], []):
            self.assertEqual(self._exit(argv)[0], 2, argv)

    def test_an_image_for_native_is_2(self):
        code, said = self._exit(["image", "--target-cpu", "native"])
        self.assertEqual(code, 2)
        self.assertIn("never compiles for the machine that builds", said)


class Image(unittest.TestCase):
    def test_the_docker_command_line(self):
        self.assertEqual(
            image.build_argv("shop", None, []),
            ["docker", "build", "-f", "deploy/Dockerfile", "-t", "shop", "."])
        self.assertEqual(
            image.build_argv("shop:1", "x86-64-v3", ["--platform", "linux/amd64"]),
            ["docker", "build", "-f", "deploy/Dockerfile", "-t", "shop:1",
             "--build-arg", "TARGET_CPU=x86-64-v3", "--platform", "linux/amd64", "."])
        self.assertEqual(
            image.about_argv("shop"),
            ["docker", "run", "--rm", "--entrypoint", "cat", "shop", "/app/about.json"])

    def test_no_project_is_78_and_runs_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            err = io.StringIO()
            old = os.getcwd()
            os.chdir(tmp)
            try:
                with contextlib.redirect_stderr(err):
                    code = cli.main(["image"])
            finally:
                os.chdir(old)
        self.assertEqual(code, 78)
        self.assertIn("there is no src/server.mojo", err.getvalue())


class Dev(unittest.TestCase):
    def test_a_snapshot_sees_an_edit_a_new_file_and_pyproject_and_nothing_else(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            (project / "src" / "deep").mkdir(parents=True)
            (project / "bin").mkdir()
            (project / "src" / "server.mojo").write_text("a")
            (project / "pyproject.toml").write_text("p")
            first = dev.snapshot(project)
            self.assertEqual(dev.snapshot(project), first)

            (project / "bin" / "server").write_text("built")
            (project / "README.md").write_text("prose")
            (project / "src" / ".server.mojo.swp").write_text("vim")
            self.assertEqual(dev.snapshot(project), first)

            (project / "src" / "server.mojo").write_text("ab")
            second = dev.snapshot(project)
            self.assertNotEqual(second, first)
            (project / "src" / "deep" / "more.mojo").write_text("n")
            third = dev.snapshot(project)
            self.assertNotEqual(third, second)
            (project / "pyproject.toml").write_text("pq")
            fourth = dev.snapshot(project)
            self.assertNotEqual(fourth, third)
            (project / "src" / "deep" / "more.mojo").unlink()
            self.assertNotEqual(dev.snapshot(project), fourth)

    def _child(self, body):
        child = subprocess.Popen([sys.executable, "-c", body], stdout=subprocess.PIPE)
        child.stdout.readline()  # its handlers are installed
        return child

    def test_stop_waits_for_the_pid_to_be_gone(self):
        child = self._child(
            "import signal, sys, time\n"
            "signal.signal(signal.SIGTERM, lambda *a: (time.sleep(0.3), sys.exit(0)))\n"
            "print('up', flush=True)\n"
            "time.sleep(60)\n")
        killed = dev.stop(child, wait=5)
        self.assertFalse(killed)
        self.assertEqual(child.poll(), 0)

    def test_a_server_that_ignores_sigterm_is_killed_and_named(self):
        child = self._child(
            "import signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('up', flush=True)\n"
            "time.sleep(60)\n")
        err = io.StringIO()
        t0 = time.time()
        with contextlib.redirect_stderr(err):
            killed = dev.stop(child, wait=0.5)
        self.assertTrue(killed)
        self.assertLess(time.time() - t0, 5)
        self.assertEqual(child.poll(), -signal.SIGKILL)
        self.assertIn(f"pid {child.pid} did not exit within 0.5 s of SIGTERM; sent SIGKILL",
                      err.getvalue())

    def test_the_wait_is_the_drain_plus_one(self):
        self.assertEqual(dev.STOP_SECONDS, 6.0)

    def test_baselines_are_build_serves(self):
        self.assertEqual(build.baseline_cpu("darwin", "arm64"), "apple-m1")
        self.assertEqual(build.baseline_cpu("linux", "aarch64"), "generic")
        self.assertEqual(build.baseline_cpu("linux", "x86_64"), "x86-64-v2")


class New(unittest.TestCase):
    def _new(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["new"] + argv)
        return code, out.getvalue(), err.getvalue()

    def test_a_name_that_cannot_be_three_things_at_once_is_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            for bad in ("Shop", "9lives", "my_app", "x.y", "a" * 41, "caf\u00e9"):
                code, _, err = self._new([os.path.join(tmp, bad)])
                self.assertEqual(code, 2, bad)
                self.assertEqual(
                    err,
                    f"m0 new: '{bad}' is not a usable name (lowercase letters, "
                    "digits and hyphens, starting with a letter, at most 40)\n",
                )
                self.assertFalse(os.path.exists(os.path.join(tmp, bad)))

    def test_a_directory_with_something_in_it_is_2_and_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "shop"
            target.mkdir()
            (target / "keep").write_text("mine")
            code, _, err = self._new([str(target)])
            self.assertEqual(code, 2)
            self.assertEqual(
                err,
                f"m0 new: {target} exists and is not empty "
                "(choose another name, or empty it)\n",
            )
            self.assertEqual(sorted(os.listdir(target)), ["keep"])

    def test_a_failing_early_check_is_said_and_new_still_exits_0(self):
        """`new` runs before a venv exists, so it asks only what it can --
        and a machine with no C compiler still gets its application."""
        listed = list(checks.CHECKS)
        no_cc = checks.Result("c-compiler", False, "there is no cc here", "install one")
        never = checks.Result("mojo-installed", False, "NOT ASKED", "NOT ASKED")
        checks.CHECKS[:] = [
            (name, (lambda project, r=no_cc: r) if name == "c-compiler"
             else (lambda project, r=never: r) if name == "mojo-installed" else check)
            for name, check in listed
        ]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                code, out, err = self._new([os.path.join(tmp, "shop")])
        finally:
            checks.CHECKS[:] = listed
        self.assertEqual((code, err), (0, ""))
        self.assertIn("before `m0 build`:\n    there is no cc here (install one)\n", out)
        self.assertNotIn("NOT ASKED", out)

    def test_dot_files_are_stored_without_their_dot(self):
        self.assertEqual(str(new.target_path("dot-gitignore")), ".gitignore")
        self.assertEqual(
            str(new.target_path("dot-github/workflows/test.yml")),
            os.path.join(".github", "workflows", "test.yml"),
        )
        self.assertEqual(str(new.target_path("src/dot-matrix.mojo")),
                         os.path.join("src", ".matrix.mojo"))

    def test_every_manifest_name_is_a_file_this_wheel_carries(self):
        root = paths.PACKAGE / "templates"
        self.assertEqual(sorted(new.MANIFEST), sorted(new.TEMPLATES))
        for name in new.COMMON:
            self.assertTrue((root / "_common" / name).is_file(), name)
        for template, names in new.MANIFEST.items():
            for name in names:
                self.assertTrue((root / template / name).is_file(), (template, name))

    def test_both_templates_write_their_manifest_and_leave_no_token(self):
        for template in new.TEMPLATES:
            with tempfile.TemporaryDirectory() as tmp:
                target = Path(tmp) / "corner-shop"
                code, out, err = self._new([str(target), "--template", template])
                self.assertEqual((code, err), (0, ""))
                wrote = sorted(
                    str(p.relative_to(target)) for p in target.rglob("*") if p.is_file()
                )
                self.assertEqual(wrote, new.written_paths(template))
                for path in wrote:
                    self.assertNotIn("__M0_", (target / path).read_text(), path)
                self.assertTrue(os.access(target / "smoke.sh", os.X_OK))
                self.assertIn("uv sync", out)
                pins = (target / "pyproject.toml").read_text()
                self.assertIn(f'"m0=={checks.m0_version()}"', pins)
                self.assertIn(f'"mojo=={paths.build_info()["gated_mojo"][0]}"', pins)
                self.assertIn('name = "corner-shop"', pins)


if __name__ == "__main__":
    unittest.main()
