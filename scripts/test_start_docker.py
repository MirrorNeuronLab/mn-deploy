"""Offline startup tests: every host command is replaced with a fake."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'install.sh'


class StartDockerTests(unittest.TestCase):
    def run_start(self, os_name='Darwin', ready=False, fail=False, context='default',
                  endpoint='unix:///var/run/docker.sock', args=(), uid='1000', never=False,
                  missing=False, attempts='2'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            fake = '''#!/bin/bash
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
'''
            for name in ('docker', 'uname', 'id', 'open', 'systemctl', 'service', 'sudo', 'sleep'):
                if missing and name == 'docker':
                    continue
                path = bin_dir / name
                path.write_text(fake)
                path.chmod(0o755)
            env = {**os.environ, 'PATH': f'{bin_dir}:/usr/bin:/bin',
                   'HOME': str(root / 'home'), 'MN_HOME': str(root / 'mn'),
                   'TEST_ROOT': str(root), 'TEST_OS': os_name, 'TEST_UID': uid,
                   'TEST_READY': str(int(ready)), 'TEST_FAIL': str(int(fail)),
                   'TEST_NEVER': str(int(never)), 'TEST_CONTEXT': context,
                   'TEST_ENDPOINT': endpoint, 'MN_DOCKER_START_ATTEMPTS': attempts}
            for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'MN_INSTALL_VERSION'):
                env.pop(key, None)
            result = subprocess.run(['/bin/bash', str(INSTALLER), '--start-docker', *args],
                                    env=env, text=True, capture_output=True, timeout=10)
            self.assertFalse((root / 'mn').exists())
            self.assertFalse((root / 'home').exists())
            log = (root / 'log').read_text() if (root / 'log').exists() else ''
            return result, log

    def test_already_running(self):
        result, log = self.run_start(ready=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(log, 'docker info\n')

    def test_macos(self):
        result, log = self.run_start()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('open -a Docker\n', log)
        self.assertNotIn('sudo', log)

    def test_linux_system(self):
        for uid in ('0', '1000'):
            with self.subTest(uid=uid):
                result, log = self.run_start(os_name='Linux', uid=uid)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue('systemctl start docker\n' in log or 'service docker start\n' in log)
                self.assertEqual('sudo -n' in log, uid != '0')

    def test_linux_user_services(self):
        for context, endpoint, service in (
            ('desktop-linux', 'unix:///home/user/.docker/desktop/docker.sock', 'docker-desktop'),
            ('rootless', 'unix:///run/user/1000/docker.sock', 'docker'),
        ):
            with self.subTest(context=context):
                result, log = self.run_start(os_name='Linux', context=context, endpoint=endpoint)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f'systemctl --user start {service}\n', log)
                self.assertNotIn('sudo', log)

    def test_windows_bash(self):
        result, log = self.run_start(os_name='MINGW64_NT-10.0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('docker desktop start\n', log)

    def test_start_failure(self):
        for os_name in ('Darwin', 'Linux', 'MSYS_NT-10.0'):
            with self.subTest(os_name=os_name):
                result, _ = self.run_start(os_name=os_name, fail=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Next:', result.stdout)

    def test_timeout(self):
        result, _ = self.run_start(never=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('startup timeout', result.stdout)

    def test_remote_and_unsupported(self):
        for options in ({'endpoint': 'ssh://host'}, {'os_name': 'FreeBSD'}):
            result, log = self.run_start(**options)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('open ', log)
            self.assertNotIn('systemctl ', log)
            self.assertIn('Next:', result.stdout)

    def test_conflicts_before_host_commands(self):
        for args in (('--reset',), ('--detect-only',), ('--mode', 'local'),
                     ('--version', 'v1.3.57'), ('--build-membrane',), ('--yes',)):
            with self.subTest(args=args):
                result, log = self.run_start(args=args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(log, '')

    def test_help(self):
        result, log = self.run_start(args=('--help',))
        self.assertEqual(result.returncode, 0)
        self.assertIn('--start-docker', result.stdout)
        self.assertEqual(log, '')

    def test_missing_docker(self):
        result, log = self.run_start(missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Docker CLI is not installed', result.stdout)
        self.assertIn('Next:', result.stdout)
        self.assertEqual(log, '')

    def test_invalid_wait_configuration(self):
        for attempts in ('0', '-1', 'text'):
            result, log = self.run_start(attempts=attempts)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('positive integer', result.stdout)
            self.assertEqual(log, '')


if __name__ == '__main__':
    unittest.main()
