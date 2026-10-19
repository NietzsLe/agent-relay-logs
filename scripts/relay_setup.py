#!/usr/bin/env python3
"""Install, uninstall, and inspect agent-relay-logs in a target repository.

Design goals:
- Touch only `.relay/`, `.gitignore`, `AGENTS.md`, and `CLAUDE.md` in the target.
- Never overwrite a whole file: insert/replace a marker block.
- Be idempotent: running install/uninstall twice is safe.
- Preserve `.relay/data` unless the user explicitly asks for `--purge`.
- Keep the runtime dependency-free (Python 3 standard library only).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

VERSION = "2.0.0"
REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGE = REPO_ROOT / "package"
TEMPLATES = REPO_ROOT / "templates"

BEGIN = "<!-- BEGIN relay-logs -->"
END = "<!-- END relay-logs -->"
BLOCK_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
MANIFEST_NAME = "install.json"
RUNTIME_FILES = ("relay", "README.md", "SNIPPET.md")
GITIGNORE_ENTRIES = {".relay", ".relay/"}
TARGET_FILES = (
    ("AGENTS.md", "agents-block.md", "--skip-agents", "no-agents"),
    ("CLAUDE.md", "claude-block.md", "--skip-claude", "no-claude"),
)


class SetupError(RuntimeError):
    pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def say(msg, quiet=False):
    if not quiet:
        print(msg)


def fail(msg):
    raise SetupError(msg)


def target_path(value):
    p = Path(value).expanduser().resolve()
    if not p.is_dir():
        fail("target is not a directory: %s" % p)
    return p


def read_text(path):
    """Return (text with LF, used_crlf, used_bom). Raise on non-UTF-8."""
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    if bom:
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as ex:
        fail("cannot read %s as UTF-8: %s" % (path, ex))
    crlf = "\r\n" in text
    return text.replace("\r\n", "\n").replace("\r", "\n"), crlf, bom


def write_text(path, text, crlf=False, bom=False, backup=False):
    """Atomically write text, preserving CRLF/BOM when requested."""
    data = text.replace("\n", "\r\n") if crlf else text
    raw = data.encode("utf-8")
    if bom:
        raw = b"\xef\xbb\xbf" + raw

    if backup and path.exists():
        dst = path.with_name(path.name + ".relay-backup-" + stamp())
        n = 1
        while dst.exists():
            dst = path.with_name(path.name + ".relay-backup-%s-%d" % (stamp(), n))
            n += 1
        shutil.copy2(path, dst)

    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".relay-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(raw)
        if path.exists():
            os.chmod(tmp, path.stat().st_mode & 0o777)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def template_block(name):
    path = TEMPLATES / name
    if not path.is_file():
        fail("missing template: %s" % path)
    text, _, _ = read_text(path)
    return text.strip() + "\n"


def upsert_block(path, block, dry_run, backup, header):
    """Insert one marker block, or replace existing blocks in place."""
    if path.exists():
        text, crlf, bom = read_text(path)
        begins, ends = text.count(BEGIN), text.count(END)
        if begins != ends:
            fail("%s has unbalanced relay markers (%d BEGIN, %d END); fix it manually" % (path, begins, ends))
        if begins:
            state = {"first": True}

            def repl(_match):
                if state["first"]:
                    state["first"] = False
                    return block.strip()
                return ""

            new, count = BLOCK_RE.subn(repl, text)
            action = "updated" if count == 1 else "updated (removed %d duplicate block(s))" % (count - 1)
        else:
            base = text.rstrip()
            new = (base + "\n\n" if base else "") + block.strip() + "\n"
            action = "added"
        if not dry_run:
            write_text(path, new, crlf, bom, backup)
        return action

    if not dry_run:
        write_text(path, header + "\n\n" + block.strip() + "\n", backup=backup)
    return "created"


def remove_block(path, dry_run, backup):
    if not path.exists():
        return "missing"
    text, crlf, bom = read_text(path)
    begins, ends = text.count(BEGIN), text.count(END)
    if begins != ends:
        fail("%s has unbalanced relay markers (%d BEGIN, %d END); fix it manually" % (path, begins, ends))
    if begins == 0:
        return "no block"
    new, count = BLOCK_RE.subn("", text)
    new = re.sub(r"\n{3,}", "\n\n", new)
    new = (new.rstrip() + "\n") if new.strip() else ""
    if not dry_run:
        write_text(path, new, crlf, bom, backup)
    return "removed %d block(s)" % count


def runtime_version(path=None):
    """Read the version string of a relay runtime file (best effort)."""
    path = path or (PACKAGE / "relay")
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "?"
    match = re.search(r'^VERSION\s*=\s*"([^"]+)"', text, re.M)
    return match.group(1) if match else "?"


def install_package(target, force, dry_run):
    relay_dir = target / ".relay"
    if relay_dir.exists() and not relay_dir.is_dir():
        fail("%s exists and is not a directory" % relay_dir)

    new_version = runtime_version()
    actions = []
    for name in RUNTIME_FILES:
        src = PACKAGE / name
        if not src.is_file():
            fail("missing package file: %s" % src)
        dst = relay_dir / name
        existed = dst.exists()
        if existed:
            try:
                same = src.read_bytes() == dst.read_bytes()
            except OSError:
                same = False
            if same:
                actions.append("%s: unchanged" % name)
                continue
            if not force:
                if name == "relay":
                    actions.append("relay: kept existing (v%s; use --force to update to v%s)"
                                   % (runtime_version(dst), new_version))
                else:
                    actions.append("%s: kept existing (use --force to update)" % name)
                continue
        if not dry_run:
            relay_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        actions.append("%s: %s" % (name, "updated" if existed else "created"))

    if not dry_run:
        relay = relay_dir / "relay"
        if relay.exists():
            relay.chmod(relay.stat().st_mode | 0o111)
    return actions


def ensure_gitignore(target, dry_run):
    path = target / ".gitignore"
    if path.exists():
        text, crlf, bom = read_text(path)
        if any(line.strip() in GITIGNORE_ENTRIES for line in text.splitlines()):
            return False, False, "already present"
        base = text.rstrip()
        new = (base + "\n" if base else "") + ".relay/\n"
        if not dry_run:
            write_text(path, new, crlf, bom)
        return True, False, "added .relay/"

    if not dry_run:
        write_text(path, ".relay/\n")
    return True, True, "created with .relay/"


def remove_gitignore(target, manifest, dry_run):
    path = target / ".gitignore"
    if not path.exists():
        return "missing"
    if manifest.get("gitignore_added") is False:
        return "kept (not added by relay)"

    text, crlf, bom = read_text(path)
    lines = text.splitlines()
    kept = [line for line in lines if line.strip() != ".relay/"]
    if len(kept) == len(lines):
        return "no .relay/ line"

    new = "\n".join(kept)
    new = (new.rstrip() + "\n") if new.strip() else ""
    if not dry_run:
        write_text(path, new, crlf, bom)
    if manifest.get("gitignore_created") and not new.strip():
        if not dry_run:
            path.unlink()
        return "removed .relay/ line and deleted empty .gitignore"
    return "removed .relay/ line"


def load_manifest(target):
    path = target / ".relay" / MANIFEST_NAME
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_manifest(target, data, dry_run):
    if dry_run:
        return
    relay_dir = target / ".relay"
    relay_dir.mkdir(parents=True, exist_ok=True)
    path = relay_dir / MANIFEST_NAME
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def cmd_install(args):
    target = target_path(args.target)
    if not PACKAGE.is_dir():
        fail("package directory not found: %s" % PACKAGE)

    say("agent-relay-logs install %s" % VERSION)
    say("  target: %s" % target)
    say("  mode:   %s" % ("dry-run (no writes)" if args.dry_run else "write"))

    for action in install_package(target, args.force, args.dry_run):
        say("  package  %s" % action, args.quiet)

    if args.no_gitignore:
        gi_added, gi_created, gi_msg = False, False, "skipped"
    else:
        gi_added, gi_created, gi_msg = ensure_gitignore(target, args.dry_run)
    say("  .gitignore: %s" % gi_msg, args.quiet)

    manifest = load_manifest(target)
    blocks = []
    created_files = []
    for filename, template, _flag, _dest in TARGET_FILES:
        skip = (filename == "AGENTS.md" and args.skip_agents) or (filename == "CLAUDE.md" and args.skip_claude)
        if skip:
            say("  %s: skipped" % filename, args.quiet)
            continue
        path = target / filename
        existed = path.exists()
        if not existed and args.no_create:
            say("  %s: missing (skipped; --no-create)" % filename, args.quiet)
            continue
        action = upsert_block(
            path,
            template_block(template),
            args.dry_run,
            args.backup,
            "# " + filename,
        )
        say("  %s: %s" % (filename, action), args.quiet)
        blocks.append(filename)
        if not existed:
            created_files.append(filename)

    manifest.update({
        "version": VERSION,
        "runtime_version": runtime_version(),
        "target": str(target),
        "last_installed_at": now(),
        "gitignore_added": bool(manifest.get("gitignore_added") or gi_added),
        "gitignore_created": bool(manifest.get("gitignore_created") or gi_created),
        "files": sorted(set(manifest.get("files", [])) | set(blocks)),
        "created_files": sorted(set(manifest.get("created_files", [])) | set(created_files)),
    })
    manifest.setdefault("first_installed_at", now())
    save_manifest(target, manifest, args.dry_run)
    say("  manifest: %s" % ("would write" if args.dry_run else "written"), args.quiet)

    say("")
    if args.dry_run:
        say("dry run complete: no files were written.")
    else:
        say("done. Verify with:")
        say("  %s/.relay/relay doctor" % target)
        say("  %s/.relay/relay --agent verify --session verify-%s start \"install check\"" % (target, stamp()))
    return 0


def cmd_uninstall(args):
    target = target_path(args.target)
    manifest = load_manifest(target)

    say("agent-relay-logs uninstall %s" % VERSION)
    say("  target: %s" % target)
    say("  mode:   %s" % ("dry-run (no writes)" if args.dry_run else "write"))

    for filename, _template, _flag, _dest in TARGET_FILES:
        skip = (filename == "AGENTS.md" and args.skip_agents) or (filename == "CLAUDE.md" and args.skip_claude)
        if skip:
            say("  %s: skipped" % filename, args.quiet)
            continue
        result = remove_block(target / filename, args.dry_run, args.backup)
        say("  %s: %s" % (filename, result), args.quiet)

    if args.no_gitignore:
        say("  .gitignore: skipped", args.quiet)
    else:
        say("  .gitignore: %s" % remove_gitignore(target, manifest, args.dry_run), args.quiet)

    for filename in manifest.get("created_files", []):
        path = target / filename
        if not path.exists():
            continue
        text, _, _ = read_text(path)
        if text.strip() in ("", "# " + filename):
            if not args.dry_run:
                path.unlink()
            say("  %s: deleted (created by installer)" % filename, args.quiet)

    relay_dir = target / ".relay"
    if args.keep_relay:
        say("  .relay: kept (--keep-relay)", args.quiet)
    elif not relay_dir.exists():
        say("  .relay: not present", args.quiet)
    elif args.purge:
        if not args.dry_run:
            shutil.rmtree(relay_dir)
        say("  .relay: purged", args.quiet)
    else:
        dest = target / (".relay.removed-" + stamp())
        n = 1
        while dest.exists():
            dest = target / (".relay.removed-%s-%d" % (stamp(), n))
            n += 1
        if not args.dry_run:
            shutil.move(str(relay_dir), str(dest))
        say("  .relay: moved to %s" % dest.name, args.quiet)

    say("")
    if args.dry_run:
        say("dry run complete: no files were written.")
    else:
        say("done. Review the target's git diff before committing.")
    return 0


def cmd_doctor(args):
    target = target_path(args.target)
    ok = True
    print("agent-relay-logs doctor %s" % VERSION)
    print("target: %s" % target)

    relay = target / ".relay" / "relay"
    if relay.is_file():
        executable = os.access(relay, os.X_OK)
        print("relay: present (%s)" % ("executable" if executable else "NOT executable"))
        ok = ok and executable
    else:
        print("relay: MISSING")
        ok = False

    for filename in ("AGENTS.md", "CLAUDE.md"):
        path = target / filename
        if not path.exists():
            print("%s: absent" % filename)
            continue
        text, _, _ = read_text(path)
        begins, ends = text.count(BEGIN), text.count(END)
        status = "ok" if begins == ends == 1 else "PROBLEM"
        print("%s: %d BEGIN / %d END (%s)" % (filename, begins, ends, status))
        if begins != ends or begins > 1:
            ok = False

    gitignore = target / ".gitignore"
    if gitignore.exists():
        text, _, _ = read_text(gitignore)
        present = any(line.strip() in GITIGNORE_ENTRIES for line in text.splitlines())
        print(".gitignore: %s" % ("contains .relay/" if present else "MISSING .relay/"))
        ok = ok and present
    else:
        print(".gitignore: absent (MISSING .relay/)")
        ok = False

    manifest = load_manifest(target)
    if manifest:
        print("manifest: version %s, installed %s" % (manifest.get("version", "?"), manifest.get("last_installed_at", "?")))
    else:
        print("manifest: absent (installation may be old or manual)")

    if relay.is_file():
        print("-- relay doctor --")
        proc = subprocess.run([sys.executable, str(relay), "doctor"], cwd=str(target))
        if proc.returncode:
            ok = False

    print("result: %s" % ("OK" if ok else "PROBLEMS FOUND"))
    return 0 if ok else 1


def build_parser():
    parser = argparse.ArgumentParser(
        prog="relay_setup.py",
        description="Install, uninstall, or inspect agent-relay-logs in a target repository.",
    )
    parser.add_argument("--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="cmd", required=True)

    install = sub.add_parser("install", help="install the runtime and marker blocks")
    install.add_argument("--target", default=".", help="target repository (default: current directory)")
    install.add_argument("--force", action="store_true", help="update existing .relay runtime files")
    install.add_argument("--dry-run", action="store_true", help="show actions without writing")
    install.add_argument("--backup", action="store_true", help="back up AGENTS.md/CLAUDE.md before editing")
    install.add_argument("--skip-agents", action="store_true", help="do not touch AGENTS.md")
    install.add_argument("--skip-claude", action="store_true", help="do not touch CLAUDE.md")
    install.add_argument("--no-create", action="store_true", help="do not create a missing AGENTS.md/CLAUDE.md")
    install.add_argument("--no-gitignore", action="store_true", help="do not modify .gitignore")
    install.add_argument("--quiet", action="store_true")
    install.set_defaults(func=cmd_install)

    uninstall = sub.add_parser("uninstall", help="remove marker blocks and the runtime")
    uninstall.add_argument("--target", default=".", help="target repository (default: current directory)")
    uninstall.add_argument("--dry-run", action="store_true", help="show actions without writing")
    uninstall.add_argument("--purge", action="store_true", help="delete .relay/ instead of moving it aside")
    uninstall.add_argument("--keep-relay", action="store_true", help="remove only the instructions; keep .relay/")
    uninstall.add_argument("--backup", action="store_true", help="back up AGENTS.md/CLAUDE.md before editing")
    uninstall.add_argument("--skip-agents", action="store_true", help="do not touch AGENTS.md")
    uninstall.add_argument("--skip-claude", action="store_true", help="do not touch CLAUDE.md")
    uninstall.add_argument("--no-gitignore", action="store_true", help="do not modify .gitignore")
    uninstall.add_argument("--quiet", action="store_true")
    uninstall.set_defaults(func=cmd_uninstall)

    doctor = sub.add_parser("doctor", help="check an installed target")
    doctor.add_argument("--target", default=".", help="target repository (default: current directory)")
    doctor.set_defaults(func=cmd_doctor)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except SetupError as ex:
        print("error: %s" % ex, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
