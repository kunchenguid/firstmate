#!/usr/bin/env python3
"""Bounded local media subprocesses, with no inherited credentials.

Owns a process group until exit, timeout or output overflow, then reaps it.
Only trusted executables receive a validated local file, never shell text.
The caller chooses wall time and output limits; each child also gets CPU and
file-size limits. This is resource containment, not an OS security sandbox.
"""

import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

from fm_whatsapp_store import BridgeError


def clean_environment(directory):
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(directory),
            "TMPDIR": str(directory), "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
            "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2", "TOKENIZERS_PARALLELISM": "false"}


def run_local(argv, directory, timeout=30, max_output=500_000):
    # A separate launcher installs limits without preexec_fn in a threaded host.
    command = [sys.executable, str(Path(__file__).resolve()), str(timeout), *map(str, argv)]
    owns_group = os.environ.get("FM_WA_PROCESS_GROUP") != "1"
    environment = clean_environment(directory)
    environment["FM_WA_PROCESS_GROUP"] = "1"
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, cwd=directory,
                               env=environment, start_new_session=owns_group)
    selector = selectors.DefaultSelector()
    output = bytearray()
    total = 0
    deadline = time.monotonic() + timeout
    memory_check = 0
    try:
        for stream in (process.stdout, process.stderr):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BridgeError("processamento local excedeu o tempo limite")
            if owns_group and time.monotonic() >= memory_check:
                usage = subprocess.run(["/bin/ps", "-axo", "pgid=,rss="], capture_output=True,
                                       text=True, timeout=3, check=True)
                rss = sum(int(fields[1]) for line in usage.stdout.splitlines()
                          if len(fields := line.split()) == 2 and fields[0] == str(process.pid))
                if rss > 1_500_000:
                    raise BridgeError("processamento local excedeu o limite de memória")
                memory_check = time.monotonic() + 0.5
            for key, _ in selector.select(min(remaining, 0.2)):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                total += len(chunk)
                if total > max_output:
                    raise BridgeError("processamento local excedeu o limite de saída")
                if key.fileobj is process.stdout:
                    output.extend(chunk)
        process.wait(timeout=max(0.01, deadline - time.monotonic()))
        if process.returncode:
            raise BridgeError("processamento local falhou; conteúdo inválido ou dependência indisponível")
        return bytes(output)
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        raise BridgeError("processamento local não concluiu dentro dos limites") from error
    finally:
        # Also remove descendants that survived the direct child's exit.
        try:
            if owns_group:
                os.killpg(process.pid, signal.SIGKILL)
            elif process.poll() is None:
                process.kill()
        except ProcessLookupError:
            pass
        process.wait()
        selector.close()
        process.stdout.close()
        process.stderr.close()


if __name__ == "__main__":
    import resource
    os.umask(0o077)
    seconds = int(sys.argv[1])
    resource.setrlimit(resource.RLIMIT_CPU, (seconds, seconds))
    resource.setrlimit(resource.RLIMIT_FSIZE, (32_000_000, 32_000_000))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    # Darwin's RLIMIT_AS is not supported reliably; the parent enforces time
    # and output, and decoders enforce dimensions, duration and allocation size.
    if sys.platform != "darwin":
        resource.setrlimit(resource.RLIMIT_AS, (2_500_000_000, 2_500_000_000))
    os.execvpe(sys.argv[2], sys.argv[2:], os.environ)
