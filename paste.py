#!/usr/bin/env python3
import sys
import subprocess
import urllib.parse
import shutil
import os
import datetime


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


def transfer_paths(paths, target_dir, action="copy"):
    """Copy (or move, when action == 'cut') the given paths into target_dir."""
    target_real = os.path.realpath(target_dir)
    for src in paths:
        try:
            # Skip no-op transfers onto the folder the item already lives in;
            # copying a file onto itself would otherwise raise SameFileError.
            if os.path.realpath(os.path.dirname(src)) == target_real:
                continue
            # Skip copying a directory onto itself or into one of its own
            # descendants; copytree would otherwise recurse into the destination
            # it just created (nested self-copy / RecursionError).
            src_real = os.path.realpath(src)
            if os.path.isdir(src) and os.path.commonpath([src_real, target_real]) == src_real:
                continue
            if action == "cut":
                shutil.move(src, target_dir)
            elif os.path.isdir(src):
                dest = os.path.join(target_dir, os.path.basename(src))
                shutil.copytree(src, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(src, target_dir)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)


def handle_drop(target_dir, uris):
    """Copy files dropped onto the widget (passed as file:// URIs) into target_dir."""
    paths = [p for p in (uri_to_path(u) for u in uris) if p]
    if paths:
        transfer_paths(paths, target_dir, "copy")


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
        sys.exit(0)

    lines = [line.strip() for line in clip.split('\n') if line.strip()]
    if not lines:
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
        sys.exit(0)

    transfer_paths(paths, target_dir, action)


def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    # Drop mode: paste.py --drop <target_dir> <uri> [<uri> ...]
    if sys.argv[1] == "--drop":
        if len(sys.argv) < 3:
            sys.exit(1)
        handle_drop(sys.argv[2], sys.argv[3:])
        return

    # Clipboard mode: paste.py <target_dir>
    handle_clipboard(sys.argv[1])


if __name__ == "__main__":
    main()
