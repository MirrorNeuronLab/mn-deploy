"""Offline startup tests: every host command is replaced with a fake."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"


class StartDockerTests(unittest.TestCase):
    def run_start(
        self,
        os_name="Darwin",
        ready=False,
        fail=False,
        context="default",
        endpoint="unix:///var/run/docker.sock",
        args=(),
        uid="1000",
        never=False,
        missing=False,
        attempts="2",
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake = """#!/bin/bash
name=${0##*/}
printf '%s %s\\n' "$name" "$*" >> "$TEST_ROOT/log"
case "$name:$*" in
  'uname:-s') echo "$TEST_OS" ;;
  'id:-u') echo "$TEST_UID" ;;
  'docker:info') [ "$TEST_READY" = 1 ] || { [ "$TEST_NEVER" != 1 ] && [ -f "$TEST_ROOT/started" ]; } ;;
  'docker:context show') echo "$TEST_CONTEXT" ;;
  'docker:context inspect '*) echo "$TEST_ENDPOINT" ;;
  'sudo:-n '*) shift; exec "$@" ;;
  open:*|systemctl:*|service:*|'docker:desktop start')
    [ "$TEST_FAIL" != 1 ] || exit 1
    touch "$TEST_ROOT/started" ;;
  sleep:*) ;;
  *) exit 99 ;;
esac
"""
            for name in (
                "docker",
                "uname",
                "id",
                "open",
                "systemctl",
                "service",
                "sudo",
                "sleep",
            ):
                if missing and name == "docker":
                    continue
                path = bin_dir / name
                path.write_text(fake)
                path.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "HOME": str(root / "home"),
                "MN_HOME": str(root / "mn"),
                "TEST_ROOT": str(root),
                "TEST_OS": os_name,
                "TEST_UID": uid,
                "TEST_READY": str(int(ready)),
                "TEST_FAIL": str(int(fail)),
                "TEST_NEVER": str(int(never)),
                "TEST_CONTEXT": context,
                "TEST_ENDPOINT": endpoint,
                "MN_DOCKER_START_ATTEMPTS": attempts,
            }
            for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "MN_INSTALL_VERSION"):
                env.pop(key, None)
            result = subprocess.run(
                ["/bin/bash", str(INSTALLER), "--start-docker", *args],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertFalse((root / "mn").exists())
            self.assertFalse((root / "home").exists())
            log = (root / "log").read_text() if (root / "log").exists() else ""
            return result, log

    def test_already_running(self):
        result, log = self.run_start(ready=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(log, "docker info\n")

    def test_macos(self):
        result, log = self.run_start()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("open -a Docker\n", log)
        self.assertNotIn("sudo", log)

    def test_linux_system(self):
        for uid in ("0", "1000"):
            with self.subTest(uid=uid):
                result, log = self.run_start(os_name="Linux", uid=uid)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(
                    "systemctl start docker\n" in log or "service docker start\n" in log
                )
                self.assertEqual("sudo -n" in log, uid != "0")

    def test_linux_user_services(self):
        for context, endpoint, service in (
            (
                "desktop-linux",
                "unix:///home/user/.docker/desktop/docker.sock",
                "docker-desktop",
            ),
            ("rootless", "unix:///run/user/1000/docker.sock", "docker"),
        ):
            with self.subTest(context=context):
                result, log = self.run_start(
                    os_name="Linux", context=context, endpoint=endpoint
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"systemctl --user start {service}\n", log)
                self.assertNotIn("sudo", log)

    def test_windows_bash(self):
        result, log = self.run_start(os_name="MINGW64_NT-10.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("docker desktop start\n", log)

    def test_start_failure(self):
        for os_name in ("Darwin", "Linux", "MSYS_NT-10.0"):
            with self.subTest(os_name=os_name):
                result, _ = self.run_start(os_name=os_name, fail=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Next:", result.stdout)

    def test_timeout(self):
        result, _ = self.run_start(never=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("startup timeout", result.stdout)

    def test_remote_and_unsupported(self):
        for options in ({"endpoint": "ssh://host"}, {"os_name": "FreeBSD"}):
            result, log = self.run_start(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("open ", log)
            self.assertNotIn("systemctl ", log)
            self.assertIn("Next:", result.stdout)

    def test_conflicts_before_host_commands(self):
        for args in (
            ("--reset",),
            ("--detect-only",),
            ("--mode", "local"),
            ("--version", "v1.3.57"),
            ("--build-membrane",),
            ("--yes",),
        ):
            with self.subTest(args=args):
                result, log = self.run_start(args=args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(log, "")

    def test_help(self):
        result, log = self.run_start(args=("--help",))
        self.assertEqual(result.returncode, 0)
        self.assertIn("--start-docker", result.stdout)
        self.assertEqual(log, "")

    def test_missing_docker(self):
        result, log = self.run_start(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Docker CLI is not installed", result.stdout)
        self.assertIn("Next:", result.stdout)
        self.assertEqual(log, "")

    def test_invalid_wait_configuration(self):
        for attempts in ("0", "-1", "text"):
            result, log = self.run_start(attempts=attempts)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("positive integer", result.stdout)
            self.assertEqual(log, "")


class DockerBootstrapTests(unittest.TestCase):
    def run_install(self, *args, allow_admin=True):
        with tempfile.TemporaryDirectory(prefix="mn docker test ") as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            # Allow only these real utilities, even on hosts with Docker in /usr/bin.
            for name in (
                "basename",
                "cat",
                "chmod",
                "dirname",
                "head",
                "ln",
                "mkdir",
                "mktemp",
                "ps",
                "rm",
                "rmdir",
                "sh",
                "touch",
            ):
                (bin_dir / name).symlink_to(shutil.which(name))
            fake = root / "fake"
            fake.write_text(
                r"""#!/bin/bash
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$TEST_ROOT/log"
case "$name:$*" in
  'uname:-s') echo Linux ;;
  'id:-u'|'id:-g') echo 1000 ;;
  'id:-un') echo installer-test ;;
  'id:-nG')
    if [ "${TEST_IN_DOCKER_GROUP:-N}" = Y ]; then echo 'staff docker'; else echo staff; fi ;;
  'id:-nG installer-test')
    if [ -f "$TEST_ROOT/member" ]; then echo 'staff docker'; else echo staff; fi ;;
  'sudo:-n -v') [ "$TEST_ALLOW_ADMIN" = Y ] ;;
  'sudo:-n sh '*) shift; exec "$@" ;;
  'sudo:-n usermod -aG docker installer-test') touch "$TEST_ROOT/member" ;;
  'sudo:-n service '*|'sudo:-n systemctl '*) shift; exec "$@" ;;
  'curl:'*' https://get.docker.com -o '*)
    for output; do :; done
    printf '%s\n' 'ln -s "$TEST_ROOT/fake" "$TEST_ROOT/bin/docker"' > "$output" ;;
  'sg:docker -c '*) TEST_IN_DOCKER_GROUP=Y exec /bin/sh -c "$3" ;;
  'docker:info') [ "${TEST_IN_DOCKER_GROUP:-N}" = Y ] && [ -f "$TEST_ROOT/started" ] ;;
  'docker:context show') echo default ;;
  'docker:context inspect '*) printf 'unix://%s/docker.sock\n' "$TEST_ROOT" ;;
  'service:docker start'|'systemctl:start docker') touch "$TEST_ROOT/started" ;;
  *) exit 99 ;;
esac
"""
            )
            fake.chmod(0o755)
            for name in ("curl", "id", "service", "sg", "sudo", "systemctl", "uname"):
                (bin_dir / name).symlink_to(fake)
            source = INSTALLER.read_text()
            marker = (
                "  mn_prepare_runtime_docker || exit 1\n  mn_prepare_installer_paths"
            )
            before, found, after = source.rpartition(marker)
            self.assertTrue(found)
            # Stop on the normal binary entry point just before it installs MirrorNeuron.
            source = (
                before
                + r"""  mn_prepare_runtime_docker || exit 1
  printf 'Docker ready with <%s>\n' "${MN_PYTHON:-}"
  exit 0
  mn_prepare_installer_paths"""
                + after
            )
            result = subprocess.run(
                ["/bin/bash", "-s", "--", *args],
                input=source,
                env={
                    "PATH": str(bin_dir),
                    "HOME": str(root),
                    "TMPDIR": str(root),
                    "MN_HOME": str(root / "mn"),
                    "TEST_ROOT": str(root),
                    "TEST_ALLOW_ADMIN": "Y" if allow_admin else "N",
                    "MN_DOCKER_START_ATTEMPTS": "1",
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertFalse((root / "mn").exists())
            self.assertFalse(list(root.glob("mn-install.*")))
            self.assertFalse(list(root.glob("mn-docker-engine.*")))
            return result, (root / "log").read_text()

    def test_linux_install_resumes_stream_in_docker_group(self):
        interpreter = "/a path/python's executable"
        result, log = self.run_install("--no-start", "--python", interpreter)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Docker ready with <{interpreter}>", result.stdout)
        self.assertLess(
            log.index("https://get.docker.com"), log.index("sudo -n usermod")
        )
        self.assertLess(log.index("sudo -n usermod"), log.index("sg docker -c"))
        self.assertRegex(log, r"(?m)^(systemctl start docker|service docker start)$")

    def test_missing_admin_access_aborts_before_download(self):
        result, log = self.run_install("--no-start", allow_admin=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sudo -v", result.stdout)
        self.assertNotIn("curl ", log)


if __name__ == "__main__":
    unittest.main()
