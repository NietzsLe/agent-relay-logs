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

VERSION = "4.1.0"
REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGE = REPO_ROOT / "package"
TEMPLATES = REPO_ROOT / "templates"
HOOKS_SRC = REPO_ROOT / "scripts" / "hooks"
OPENCODE_PLUGIN = "opencode-nudge.js"
PLUGIN_DST = Path(".opencode/plugins") / OPENCODE_PLUGIN
CLAUDE_SETTINGS = Path(".claude/settings.local.json")

TICK_CMD = "[ -x .relay/relay ] && .relay/relay tick --hook 2>/dev/null | head -5 || true"
GUARD_CMD = "[ -x .relay/relay ] && .relay/relay guard --stop 2>&1 | head -10 || true"

BEGIN = "<!-- BEGIN relay-logs -->"
END = "<!-- END relay-logs -->"
BLOCK_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
BLOCK_STAMP_RE = re.compile(r"relay-logs\s+(\S+)\s+v(\d+)")
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


def template_block_version(name):
    """Version stamp of a template (templates/VERSIONS documents the scheme)."""
    path = TEMPLATES / name
    if not path.is_file():
        fail("missing template: %s" % path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as ex:
        fail("cannot read template %s: %s" % (path, ex))
    match = BLOCK_STAMP_RE.search(text)
    if not match:
        fail("template %s has no version stamp (expected '<!-- relay-logs <name> vN -->')" % name)
    return int(match.group(2))


def installed_block_version(text):
    """Version stamp found in an installed block, or None for legacy blocks."""
    match = BLOCK_STAMP_RE.search(text)
    return int(match.group(2)) if match else None


def template_block(name):
    path = TEMPLATES / name
    if not path.is_file():
        fail("missing template: %s" % path)
    text, _, _ = read_text(path)
    return text.strip() + "\n"


def upsert_block(path, block, dry_run, backup, header, template_version=None):
    """Insert one marker block, or replace existing blocks in place.

    Everything between the markers is installer-owned, so an upgrade replaces
    the whole block. Reports vOld -> vNew; skips the write when the installed
    block is already identical (idempotent, no mtime churn).
    """
    new_block = block.strip()
    if path.exists():
        text, crlf, bom = read_text(path)
        begins, ends = text.count(BEGIN), text.count(END)
        if begins != ends:
            fail("%s has unbalanced relay markers (%d BEGIN, %d END); fix it manually" % (path, begins, ends))
        if begins:
            old_v = installed_block_version(text)
            old_label = ("v%d" % old_v) if old_v is not None else "unversioned"
            new_label = ("v%d" % template_version) if template_version is not None else "template"
            state = {"first": True, "identical": True}

            def repl(match):
                if state["first"]:
                    state["first"] = False
                    if match.group(0).strip() != new_block:
                        state["identical"] = False
                    return new_block
                state["identical"] = False
                return ""

            new, count = BLOCK_RE.subn(repl, text)
            if state["identical"] and count == 1:
                return "unchanged (already %s)" % new_label
            if not dry_run:
                write_text(path, new, crlf, bom, backup)
            if count == 1:
                return "updated (%s -> %s)" % (old_label, new_label)
            return "updated (%s -> %s; removed %d duplicate block(s))" % (old_label, new_label, count - 1)
        else:
            base = text.rstrip()
            new = (base + "\n\n" if base else "") + new_block + "\n"
            action = "added"
        if not dry_run:
            write_text(path, new, crlf, bom, backup)
        return action

    if not dry_run:
        write_text(path, header + "\n\n" + new_block + "\n", backup=backup)
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


# --------------------------------------------------------------------------- hooks
def _hook_marker(text):
    return "relay tick --hook" in text or "relay guard --stop" in text


def _want_hook_entries():
    tick = {"type": "command", "command": TICK_CMD}
    guard = {"type": "command", "command": GUARD_CMD}
    return {
        "UserPromptSubmit": [{"hooks": [tick]}],
        "PostToolUse": [{"matcher": "Bash|Edit|Write", "hooks": [tick]}],
        "Stop": [{"hooks": [guard]}],
    }


def _strip_our_hooks(items):
    """Remove our hook entries from a hook-type list. Return (kept, removed)."""
    kept, removed = [], 0
    for item in items or []:
        if not isinstance(item, dict):
            kept.append(item)
            continue
        hooks = item.get("hooks")
        if not isinstance(hooks, list):
            if _hook_marker(json.dumps(item)):
                removed += 1
                continue
            kept.append(item)
            continue
        rest = [h for h in hooks if not _hook_marker(json.dumps(h))]
        removed += len(hooks) - len(rest)
        if rest:
            item = dict(item)
            item["hooks"] = rest
            kept.append(item)
        else:
            removed += 0  # whole matcher entry dropped
    return kept, removed


def install_hooks(target, force, dry_run):
    """Install the opencode plugin and merge Claude Code hooks. Idempotent."""
    actions = []
    src = HOOKS_SRC / OPENCODE_PLUGIN
    if not src.is_file():
        fail("missing hook source: %s" % src)
    dst = target / PLUGIN_DST
    if dst.exists():
        try:
            same = src.read_bytes() == dst.read_bytes()
        except OSError:
            same = False
        if same:
            actions.append("opencode plugin: unchanged")
        elif not force:
            actions.append("opencode plugin: kept existing (use --force to update)")
        else:
            if not dry_run:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
            actions.append("opencode plugin: updated")
    else:
        if not dry_run:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        actions.append("opencode plugin: created")

    settings = target / CLAUDE_SETTINGS
    try:
        data = json.loads(settings.read_text(encoding="utf-8")) if settings.exists() else {}
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    created = not settings.exists()
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
        data["hooks"] = hooks
    added = 0
    for name, want in _want_hook_entries().items():
        have = hooks.get(name)
        if not isinstance(have, list):
            have = []
            hooks[name] = have
        blob = json.dumps(have)
        for entry in want:
            if _hook_marker(json.dumps(entry)) and _hook_marker(blob):
                continue
            have.append(entry)
            blob = json.dumps(have)
            added += 1
    if added or created:
        if not dry_run:
            settings.parent.mkdir(parents=True, exist_ok=True)
            tmp = settings.with_name(settings.name + ".tmp")
            with tmp.open("w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.replace(tmp, settings)
        actions.append("claude hooks: %s (%d added)" % ("created" if created else "merged", added))
    else:
        actions.append("claude hooks: unchanged")
    return actions, created


def remove_hooks(target, dry_run, delete_empty_settings=False):
    """Remove what install_hooks added. Never touches user content."""
    actions = []
    src = HOOKS_SRC / OPENCODE_PLUGIN
    dst = target / PLUGIN_DST
    if not dst.exists():
        actions.append("opencode plugin: absent")
    else:
        try:
            ours = src.is_file() and src.read_bytes() == dst.read_bytes()
        except OSError:
            ours = False
        if ours:
            if not dry_run:
                dst.unlink()
                for parent in (dst.parent, dst.parent.parent):
                    try:
                        parent.rmdir()
                    except OSError:
                        break
            actions.append("opencode plugin: removed")
        else:
            actions.append("opencode plugin: kept (modified by user)")

    settings = target / CLAUDE_SETTINGS
    try:
        raw = settings.read_text(encoding="utf-8") if settings.exists() else ""
        data = json.loads(raw) if raw else None
    except (OSError, ValueError):
        data = None
    if not isinstance(data, dict) or not isinstance(data.get("hooks"), dict):
        actions.append("claude hooks: absent")
        return actions
    hooks, removed_total = data["hooks"], 0
    for name in list(hooks):
        kept, removed = _strip_our_hooks(hooks.get(name))
        removed_total += removed
        if kept:
            hooks[name] = kept
        else:
            del hooks[name]
    if not hooks:
        data.pop("hooks", None)
    if removed_total:
        if not dry_run:
            if not data and delete_empty_settings:
                settings.unlink()
                try:
                    settings.parent.rmdir()
                except OSError:
                    pass
                actions.append("claude hooks: removed %d entr(y/ies), deleted empty file" % removed_total)
            else:
                if not data:
                    data = {}
                tmp = settings.with_name(settings.name + ".tmp")
                with tmp.open("w", encoding="utf-8") as f:
                    json.dump(data, f, ensure_ascii=False, indent=2)
                    f.write("\n")
                os.replace(tmp, settings)
                actions.append("claude hooks: removed %d entr(y/ies)" % removed_total)
        else:
            actions.append("claude hooks: would remove %d entr(y/ies)" % removed_total)
    else:
        actions.append("claude hooks: absent")
    return actions


def check_hooks(target):
    """Return (ok, lines) describing hook state."""
    lines, ok = [], True
    dst = target / PLUGIN_DST
    if dst.is_file():
        lines.append("opencode plugin: present")
    else:
        lines.append("opencode plugin: absent")
        ok = False
    settings = target / CLAUDE_SETTINGS
    try:
        data = json.loads(settings.read_text(encoding="utf-8")) if settings.exists() else {}
    except (OSError, ValueError):
        data = {}
    hooks = data.get("hooks") if isinstance(data, dict) else None
    if isinstance(hooks, dict) and _hook_marker(json.dumps(hooks)):
        lines.append("claude hooks: present")
    else:
        lines.append("claude hooks: absent")
        ok = False
    return ok, lines


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
    block_versions = dict(manifest.get("block_versions", {}))
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
        tver = template_block_version(template)
        action = upsert_block(
            path,
            template_block(template),
            args.dry_run,
            args.backup,
            "# " + filename,
            template_version=tver,
        )
        say("  %s: %s" % (filename, action), args.quiet)
        blocks.append(filename)
        if not args.dry_run:
            block_versions[filename] = tver
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
        "block_versions": block_versions,
    })
    manifest.setdefault("first_installed_at", now())

    if args.hooks:
        hook_actions, hooks_created = install_hooks(target, args.force, args.dry_run)
        for action in hook_actions:
            say("  hooks  %s" % action, args.quiet)
        if not args.dry_run:
            manifest["hooks"] = True
            manifest["hooks_created_settings"] = bool(
                manifest.get("hooks_created_settings") or hooks_created)
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

    for action in remove_hooks(target, args.dry_run,
                               delete_empty_settings=bool(manifest.get("hooks_created_settings"))):
        say("  hooks  %s" % action, args.quiet)

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

    for filename, template, _flag, _dest in TARGET_FILES:
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
            continue
        try:
            want = template_block_version(template)
        except SetupError:
            want = None
        have = installed_block_version(text)
        have_label = ("v%d" % have) if have is not None else "unversioned"
        if want is not None and have != want:
            print("%s: block %s installed, template is v%d (outdated — rerun install to upgrade)" % (filename, have_label, want))
        elif want is not None:
            print("%s: block v%d (up to date)" % (filename, want))

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

    hooks_ok, hook_lines = check_hooks(target)
    for line in hook_lines:
        print("%s" % line)

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
    install.add_argument("--hooks", action="store_true",
                         help="install harness hooks (opencode plugin + Claude Code hooks)")
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
