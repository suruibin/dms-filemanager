#!/usr/bin/env python3
import sys
import subprocess
import urllib.parse
import shutil
import os
import time
import datetime

CHUNK = 1024 * 1024  # 1 MiB per read/write
REPORT_INTERVAL = 0.15  # seconds between progress lines

# Progress protocol on stdout (tab-separated, one line each):
#   A\t<action>               overall action of this run: copy or move
#   T\t<total>                total bytes to transfer (after pre-scan)
#   P\t<done>\t<total>\t<name>  progress; <name> is the current item
#   E\t<path>                 one item failed
#   S\t<ok>\t<fail>           final summary
_state = {"done": 0, "total": 0, "current": "", "last_t": 0.0}


def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def report(force=False):
    now = time.monotonic()
    if force or now - _state["last_t"] >= REPORT_INTERVAL:
        _state["last_t"] = now
        emit("P\t%d\t%d\t%s" % (_state["done"], _state["total"], _state["current"]))


def uri_to_path(line):
    """Turn a single clipboard/drop line into a local filesystem path, or None."""
    line = line.strip()
    if not line:
        return None
    if line.startswith("file://"):
        line = line[7:]
    if line.startswith("localhost/"):
        line = line[9:]
    decoded = urllib.parse.unquote(line)
    return decoded if os.path.exists(decoded) else None


def tree_size(path):
    """Total byte size of a file or directory tree (symlinks count as 0)."""
    try:
        if os.path.islink(path):
            return 0
        if os.path.isfile(path):
            return os.path.getsize(path)
        total = 0
        for root, dirs, files in os.walk(path):
            for name in files:
                fp = os.path.join(root, name)
                try:
                    if not os.path.islink(fp):
                        total += os.path.getsize(fp)
                except OSError:
                    pass
        return total
    except OSError:
        return 0


def safe_copystat(src, dest):
    """copystat like cp -a: permission/unsupported metadata errors are warnings,
    not failures (e.g. NTFS/exFAT/FAT mounts that reject chmod or utime)."""
    try:
        shutil.copystat(src, dest)
    except (PermissionError, OSError):
        pass


def copy_file_progress(src, dest):
    d = os.path.dirname(dest)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(src, "rb") as fsrc, open(dest, "wb") as fdst:
        while True:
            buf = fsrc.read(CHUNK)
            if not buf:
                break
            fdst.write(buf)
            _state["done"] += len(buf)
            report()
    safe_copystat(src, dest)


def copy_tree_progress(src, dest):
    """Recursive copy preserving symlinks and timestamps (cp -a style)."""
    os.makedirs(dest, exist_ok=True)
    safe_copystat(src, dest)
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        target_root = dest if rel == "." else os.path.join(dest, rel)
        for name in dirs:
            s = os.path.join(root, name)
            if not os.path.islink(s):
                os.makedirs(os.path.join(target_root, name), exist_ok=True)
        for name in files:
            s = os.path.join(root, name)
            t = os.path.join(target_root, name)
            if os.path.islink(s):
                if os.path.lexists(t):
                    os.remove(t)
                os.symlink(os.readlink(s), t)
            else:
                copy_file_progress(s, t)
    # Bottom-up so children timestamps are set before their parents
    for root, dirs, files in os.walk(src, topdown=False):
        rel = os.path.relpath(root, src)
        target_root = dest if rel == "." else os.path.join(dest, rel)
        safe_copystat(root, target_root)


def remove_tree(path):
    if os.path.islink(path) or os.path.isfile(path):
        os.remove(path)
    else:
        shutil.rmtree(path, ignore_errors=True)


def do_job(action, src, dest):
    """Perform one transfer job. Returns True on success."""
    try:
        if action == "move":
            try:
                os.rename(src, dest)
                return True
            except OSError:
                pass  # cross-filesystem: fall through to copy + delete
        if os.path.islink(src):
            # cp -a copies the link itself, not its target
            d = os.path.dirname(dest)
            if d:
                os.makedirs(d, exist_ok=True)
            if os.path.lexists(dest):
                os.remove(dest)
            os.symlink(os.readlink(src), dest)
        elif os.path.isdir(src):
            copy_tree_progress(src, dest)
        else:
            copy_file_progress(src, dest)
        if action == "move":
            remove_tree(src)
        return True
    except Exception as e:
        try:
            if os.path.isfile(dest) or os.path.islink(dest):
                os.remove(dest)
        except OSError:
            pass
        emit("E\t%s\t%s" % (src, str(e).replace("\t", " ")))
        return False


def job_is_noop(src, dest):
    try:
        return os.path.realpath(src) == os.path.realpath(dest)
    except OSError:
        return False


def job_is_into_self(src, dest):
    try:
        src_real = os.path.realpath(src)
        dest_real = os.path.realpath(dest)
        return os.path.isdir(src) and os.path.commonpath([src_real, dest_real]) == src_real
    except (OSError, ValueError):
        return False


def run_jobs(jobs):
    """jobs: list of (action, src, dest) with action in ('copy', 'move')."""
    jobs = [j for j in jobs if not job_is_noop(j[1], j[2]) and not job_is_into_self(j[1], j[2])]
    if not jobs:
        emit("S\t0\t0")
        return
    emit("A\t" + jobs[0][0])
    total = 0
    for _, src, _ in jobs:
        total += tree_size(src)
    _state["total"] = total
    emit("T\t%d" % total)
    ok = 0
    fail = 0
    for action, src, dest in jobs:
        _state["current"] = os.path.basename(src.rstrip(os.sep)) or src
        job_start = _state["done"]
        job_size = tree_size(src)
        if do_job(action, src, dest):
            ok += 1
        else:
            fail += 1  # E line already emitted by do_job with the error message
        _state["done"] = job_start + job_size
        report(force=True)
    emit("S\t%d\t%d" % (ok, fail))


def build_jobs(target_dir, paths, action):
    """Build (action, src, dest) jobs copying each path into target_dir."""
    jobs = []
    for src in paths:
        name = os.path.basename(src.rstrip(os.sep)) or src
        jobs.append((action, src, os.path.join(target_dir, name)))
    return jobs


def handle_drop(target_dir, uris):
    """Copy files dropped onto the widget (passed as file:// URIs) into target_dir."""
    paths = [p for p in (uri_to_path(u) for u in uris) if p]
    if paths:
        run_jobs(build_jobs(target_dir, paths, "copy"))
    else:
        emit("S\t0\t0")


def handle_clipboard(target_dir):
    # 1. Check clipboard MIME types for image formats
    try:
        p_types = subprocess.run(['wl-paste', '--list-types'], capture_output=True, text=True)
        types = p_types.stdout.splitlines()
    except Exception:
        types = []

    image_type = None
    for t in types:
        if t.startswith('image/'):
            image_type = t
            break

    if image_type:
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        ext = "png"
        if "jpeg" in image_type or "jpg" in image_type:
            ext = "jpg"

        filename = f"Clipboard_{timestamp}.{ext}"
        dest_path = os.path.join(target_dir, filename)

        try:
            with open(dest_path, 'wb') as f:
                subprocess.run(['wl-paste', '-t', image_type], stdout=f)
            sys.exit(0)
        except Exception as e:
            print(f"Error saving image: {e}", file=sys.stderr)
            sys.exit(1)

    # 2. Get clipboard contents for file paths
    clip = ""
    try:
        p = subprocess.run(['wl-paste', '-t', 'x-special/gnome-copied-files'], capture_output=True, text=True)
        if p.returncode == 0:
            clip = p.stdout
    except Exception:
        pass

    if not clip.strip():
        # Fallback: try plain text only if it looks like file URIs
        try:
            p = subprocess.run(['wl-paste'], capture_output=True, text=True)
            if p.returncode == 0:
                candidate = p.stdout.strip()
                # Only treat as file paths when all non-empty lines start with file://
                lines_candidate = [l.strip() for l in candidate.splitlines() if l.strip()]
                if lines_candidate and all(l.startswith("file://") for l in lines_candidate):
                    clip = candidate
        except Exception:
            pass

    if not clip.strip():
        emit("S\t0\t0")
        sys.exit(0)

    lines = [line.strip() for line in clip.split('\n') if line.strip()]
    if not lines:
        emit("S\t0\t0")
        sys.exit(0)

    action = "copy"
    file_lines = []

    if lines[0] in ("copy", "cut"):
        action = lines[0]
        file_lines = lines[1:]
    else:
        file_lines = lines

    paths = [p for p in (uri_to_path(line) for line in file_lines) if p]
    if not paths:
        emit("S\t0\t0")
        sys.exit(0)

    run_jobs(build_jobs(target_dir, paths, "copy" if action != "cut" else "move"))


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.exit(1)

    # Explicit ops mode: --ops <action> <src> <dest> [<action> <src> <dest> ...]
    if argv[0] == "--ops":
        rest = argv[1:]
        if len(rest) < 3 or len(rest) % 3 != 0:
            sys.exit(1)
        jobs = []
        for i in range(0, len(rest), 3):
            a, s, d = rest[i], rest[i + 1], rest[i + 2]
            if a not in ("copy", "move"):
                sys.exit(1)
            jobs.append((a, s, d))
        run_jobs(jobs)
        return

    # Drop mode: paste.py --drop <target_dir> <uri> [<uri> ...]
    if argv[0] == "--drop":
        if len(argv) < 3:
            sys.exit(1)
        handle_drop(argv[1], argv[2:])
        return

    # Clipboard mode: paste.py <target_dir>
    handle_clipboard(argv[0])


if __name__ == "__main__":
    main()
