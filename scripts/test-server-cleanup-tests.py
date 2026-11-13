#!/usr/bin/env python3
"""Owned, bounded fault regressions: python3 scripts/test-server-cleanup-tests.py.

Runs the real harness definitions/trap and runner tail, without starting Docker,
installing dependencies or performing API writes. Only generated fake CLI/server
PIDs are signalled. Every test has an outer deadline and exact-PID final cleanup.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "scripts/test-server.sh"
SOURCE = HARNESS.read_text()
DEFINITIONS = SOURCE.split("mode=${1:-test}", 1)[0]
RUNNER = SOURCE[SOURCE.index("export ABS_TEST_SERVER_URL="):]
CONTAINER = "a" * 64

FAKE_DOCKER = r'''
import os, sys, time
from pathlib import Path
root = Path(os.environ["CASE_ROOT"])
args = sys.argv[1:]
with (root / "calls").open("a") as out:
    out.write(repr(args) + "\n")
fault = os.environ["CASE_FAULT"]
if args[0] == "logs":
    operation = "logs"
elif args[:2] == ["rm", "-f"]:
    assert args[2:] == ["a" * 64], args
    operation = "remove"
elif args[:2] == ["container", "ls"]:
    assert "id=" + "a" * 64 in args and "--no-trunc" in args, args
    operation = "verify"
else:
    raise AssertionError(args)
if fault in (operation + "-hang", operation + "-unkillable"):
    (root / ("pid-" + str(os.getpid()))).write_text(str(os.getpid()))
    time.sleep(120)
if fault == operation + "-fail":
    sys.exit(1)
if operation == "remove" and fault != "still-live":
    (root / "live").unlink(missing_ok=True)
if operation == "verify" and (root / "live").exists():
    print("a" * 64)
'''

FAKE_NODE = r'''
import os, signal, time
from pathlib import Path
root = Path(os.environ["CASE_ROOT"])
if os.environ["CASE_FAULT"] in ("ignore-term", "cannot-stop"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
(root / ("pid-" + str(os.getpid()))).write_text(str(os.getpid()))
(root / "ready").touch()
if os.environ["CASE_FAULT"] != "already-exited":
    time.sleep(120)
'''

BODY = r'''
work=$CASE_WORK
cleanup_command_timeout=1
cleanup_term_timeout=1
cleanup_kill_timeout=1
if [[ "$CASE_BACKEND" == docker ]]; then
  container=$CASE_CONTAINER
  if [[ "$CASE_FAULT" == missing-id ]]; then
    container=
    container_requested=1
    container_name=owned-fake-no-id
  elif [[ "$CASE_FAULT" == recover-id ]]; then
    container=
    container_requested=1
  fi
  if [[ "$CASE_FAULT" == verify-unkillable ]]; then
    kill() { return 1; }
  fi
else
  # Like the real node backend's log file, do not leave the harness output pipe
  # open in a deliberately surviving child; the PID/data must still be retained.
  "$CASE_PYTHON" "$CASE_ROOT/server.py" >/dev/null 2>&1 &
  server_pid=$!
  while [[ ! -e "$CASE_ROOT/ready" ]]; do sleep 0.01; done
  if [[ "$CASE_FAULT" == already-exited ]]; then wait "$server_pid"; fi
  if [[ "$CASE_FAULT" == stopped ]]; then builtin kill -STOP "$server_pid"; fi
  if [[ "$CASE_FAULT" == cannot-stop ]]; then
    kill() {
      if [[ "${2:-}" == "$server_pid" && "$1" != -0 ]]; then return 1; fi
      builtin kill "$@"
    }
  fi
fi
exit "$CASE_STATUS"
'''


def stopped(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, timeout=2
    )
    if result.returncode == 1 and not result.stdout:
        return True
    if result.returncode != 0:
        raise RuntimeError(f"Cannot verify owned fake PID {pid}: {result.stderr}")
    return result.stdout.strip().startswith("Z")


class CleanupTests(unittest.TestCase):
    def test_owned_sidecars_match_declared_patch_values_and_exact_inventory(self):
        temporary = ROOT / ".build/server-tmp"
        temporary.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="search-generator.", dir=temporary) as directory:
            root = Path(directory)
            work = root / "data"
            work.mkdir()
            seed = [
                "audiobooks/Ada Fixture/The Synthetic Tale/01 - Part One.mp3",
                "audiobooks/Ada Fixture/The Synthetic Tale/02 - Part Two.mp3",
                "audiobooks/Ada Fixture/Single File Tale/Single File Tale.m4b",
                "podcasts/Synthetic Cast/Episode One.mp3",
            ]
            for name in seed:
                path = work / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"unchanged ordinary seed sentinel")
            # Only tone encoding is stubbed. Execute the actual owned generator and sidecar writes.
            (root / "tone.py").write_text(
                "import json, os, sys\nfrom pathlib import Path\n"
                "Path(sys.argv[1]).write_bytes(b'synthetic tone stub')\n"
                "with (Path(os.environ['CASE_ROOT']) / 'tones.jsonl').open('a') as out:\n"
                "    out.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            definition = SOURCE[SOURCE.index("make_search_media() {"):SOURCE.index("\nstart_docker() {")]
            result = subprocess.run(
                ["/bin/bash", "-c",
                 'set -euo pipefail\nwork=$CASE_WORK\n'
                 'openssl() { printf "0123456789abcdef\\n"; }\n'
                 'tone() { "$CASE_PYTHON" "$CASE_ROOT/tone.py" "$@"; }\n'
                 + definition + "\nmake_search_media\n"],
                env=dict(os.environ, CASE_ROOT=str(root), CASE_WORK=str(work), CASE_PYTHON=sys.executable),
                capture_output=True, text=True, timeout=3
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            token = "search0123456789abcdef"
            owned = set()
            for name, unique, publisher, language, year in [
                ("First", True, "First Publisher", "en", "1984"),
                ("Second", False, "Second Publisher", "fr", "2007"),
            ]:
                folder = f"search-fixtures/books/{name}"
                owned.update([f"{folder}/{name}.mp3", f"{folder}/metadata.json"])
                def values(kind):
                    return [f"{token} Shared {kind}"] + ([f"{token} Unique {kind}"] if unique else [])
                self.assertEqual(json.loads((work / folder / "metadata.json").read_bytes()), {
                    "tags": values("Tag"), "genres": values("Genre"), "narrators": values("Narrator"),
                    "publisher": publisher, "language": language, "publishedYear": year,
                })
            folder = "search-fixtures/casts/Owned Cast"
            owned.update([f"{folder}/{token} Episode {n}.mp3" for n in [1, 2]])
            owned.add(f"{folder}/metadata.json")
            self.assertEqual(json.loads((work / folder / "metadata.json").read_bytes()), {
                "tags": [f"{token} Podcast Tag"], "genres": [f"{token} Podcast Genre"], "language": "de",
            })
            self.assertEqual({str(p.relative_to(work)) for p in work.rglob("*") if p.is_file()}, set(seed) | owned)
            for name in seed:
                self.assertEqual((work / name).read_bytes(), b"unchanged ordinary seed sentinel")
            tones = [json.loads(line) for line in (root / "tones.jsonl").read_text().splitlines()]
            self.assertEqual(len(tones), 4)
            self.assertEqual([row[2] for row in tones], ["30", "40", "20", "40"])
            for index, row in enumerate(tones):
                if index < 2:
                    name = ["First", "Second"][index]
                    self.assertIn(f"artist={token} Shared Author", row)
                    self.assertIn(f"title={name}", row)
                    self.assertIn(f"album={name}", row)
                else:
                    self.assertIn(f"genre={token} Podcast Genre", row)
                    self.assertIn(f"title={token} Episode {index - 1}", row)

    def run_case(self, backend, fault="", primary=0, expected=0, retained=False):
        temporary = ROOT / ".build/server-tmp"
        temporary.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="cleanup-regression.", dir=temporary))
        work = root / "data"
        work.mkdir()
        (work / "sentinel").write_text("owned server data")
        (root / "live").touch()
        if fault == "recover-id":
            (work / "container.id").write_text(CONTAINER)
        (root / "bin").mkdir()
        docker = root / "bin/docker"
        docker.write_text(f"#!{sys.executable}\n" + FAKE_DOCKER)
        docker.chmod(0o700)
        (root / "server.py").write_text(FAKE_NODE)
        env = dict(os.environ, CASE_ROOT=str(root), CASE_WORK=str(work),
                   CASE_BACKEND=backend, CASE_FAULT=fault, CASE_STATUS=str(primary),
                   CASE_CONTAINER=CONTAINER, CASE_PYTHON=sys.executable)
        env["PATH"] = str(root / "bin") + os.pathsep + env["PATH"]
        process = subprocess.Popen(
            ["/bin/bash", "-c", DEFINITIONS + BODY, str(HARNESS)],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        try:
            try:
                output, _ = process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                self.fail(f"{backend}/{fault}: outer 8s deadline exceeded")
            self.assertEqual(process.returncode, expected, output)
            self.assertEqual(work.exists(), retained, output)
            if retained:
                self.assertTrue((work / "sentinel").is_file(), output)
                self.assertIn(str(work), output)
                resource = "owned-fake-no-id" if fault == "missing-id" else CONTAINER
                self.assertIn(resource if backend == "docker" else "PID", output)
            else:
                for path in root.glob("pid-*"):
                    self.assertTrue(stopped(int(path.read_text())), output)
            if backend == "docker" and retained:
                self.assertTrue((root / "live").exists() or fault.startswith("verify"), output)
        finally:
            # The outer guard must also contain the intentionally broken, pre-fix trap.
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
            for path in root.glob("pid-*"):
                pid = int(path.read_text())
                if not stopped(pid):
                    command = subprocess.run(
                        ["ps", "-p", str(pid), "-o", "command="],
                        capture_output=True, text=True, timeout=2, check=True
                    ).stdout
                    if str(root) not in command:
                        raise RuntimeError(f"PID identity changed; retaining {root}")
                    os.kill(pid, signal.SIGKILL)
                    deadline = time.monotonic() + 2
                    while not stopped(pid) and time.monotonic() < deadline:
                        time.sleep(0.02)
                    if not stopped(pid):
                        raise RuntimeError(f"Owned PID {pid} still live; retaining {root}")
            process.communicate(timeout=2)
            shutil.rmtree(root)

    def test_docker_removal_failure_retains_live_data_and_fails_green_body(self):
        self.run_case("docker", "remove-fail", expected=1, retained=True)

    def test_docker_primary_error_survives_cleanup_failure(self):
        self.run_case("docker", "remove-fail", primary=37, expected=37, retained=True)

    def test_docker_verified_removal(self):
        self.run_case("docker")

    def test_docker_partial_start_recovers_registered_id(self):
        self.run_case("docker", "recover-id")

    def test_docker_missing_id_retains_data(self):
        self.run_case("docker", "missing-id", expected=1, retained=True)

    def test_docker_still_present_is_not_verified(self):
        self.run_case("docker", "still-live", expected=1, retained=True)

    def test_docker_verification_failure_is_not_absence(self):
        self.run_case("docker", "verify-fail", expected=1, retained=True)

    def test_docker_verification_hang_is_bounded(self):
        self.run_case("docker", "verify-hang", expected=1, retained=True)

    def test_docker_removal_hang_is_bounded(self):
        self.run_case("docker", "remove-hang", expected=1, retained=True)

    def test_docker_verifier_that_cannot_be_killed_retains_data(self):
        self.run_case("docker", "verify-unkillable", expected=1, retained=True)

    def test_docker_log_hang_preserves_primary_error(self):
        self.run_case("docker", "logs-hang", primary=37, expected=37)

    def test_node_ignoring_term_is_bounded_and_stopped(self):
        self.run_case("node", "ignore-term")

    def test_node_normal_stop(self):
        self.run_case("node")

    def test_node_stopped_child_is_not_mistaken_for_exited(self):
        self.run_case("node", "stopped")

    def test_node_already_exited(self):
        self.run_case("node", "already-exited")

    def test_node_unverified_stop_retains_data(self):
        self.run_case("node", "cannot-stop", expected=1, retained=True)

    def test_node_primary_error_survives_unverified_stop(self):
        self.run_case("node", "cannot-stop", primary=37, expected=37, retained=True)

    def test_runner_selectors_and_primary_exit_codes(self):
        prefix = r'''
set -euo pipefail
base_url=http://127.0.0.1:1; username=root; password=synthetic; version=2.26.0
search_token=search0123456789abcdef; search_root=/search-fixtures; search_provenance=synthetic
search_only=0
unset ABS_SEARCH_CONTRACT_MODE ABS_PODCAST_WRITE_CONTRACT
log() { printf '%s\n' "$*"; }
swift() {
  printf 'STUB swift mode=%s podcast=%s args=%s\n' "${ABS_SEARCH_CONTRACT_MODE:-off}" \
    "${ABS_PODCAST_WRITE_CONTRACT:-off}" "$*"
  if [[ ${ABS_SEARCH_CONTRACT_MODE:-off} == 1 ]]; then return "$second"; else return "$first"; fi
}
'''
        for full, first, second, expected in [(1, 37, 0, 37), (1, 0, 41, 41), (0, 0, 0, 0), (0, 43, 0, 43)]:
            with self.subTest(full=full, first=first, second=second):
                result = subprocess.run(
                    ["/bin/bash", "-c", prefix +
                     f"\nsearch_contract={full}; first={first}; second={second}\n" + RUNNER,
                     str(HARNESS), "--filter", "LibraryContractTests/libraries"],
                    capture_output=True, text=True, timeout=3
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count("STUB swift"), 3 if full and not first else 1)
                # Only the podcast write pass sees ABS_PODCAST_WRITE_CONTRACT=1 (#465).
                self.assertEqual(result.stdout.count("podcast=1"), 1 if full and not first else 0)
                if full and not first:
                    self.assertIn("podcast=1 args=test --package-path Packages/AudiobookshelfKit "
                                  "--scratch-path .build/swiftpm --filter PodcastCreationContractTests", result.stdout)
                if not full:
                    self.assertIn("--filter LibraryContractTests/libraries", result.stdout)
                    self.assertNotIn("Owned search pass", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
