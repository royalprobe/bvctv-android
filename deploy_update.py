#!/usr/bin/env python3
"""
deploy_update.py – Vollständiger Deploy-Pipeline für BVCTV.

Was das Script macht (automatisch, ohne Rückfragen):
  1. Patch-Version in pubspec.yaml hochzählen  (z.B. 1.0.0+1 → 1.0.1+2)
  2. Flutter Release-APK bauen
  3. GitHub Release erstellen und APK hochladen
  4. APK per ADB auf den Fire Stick installieren (192.168.0.54:5555)

Ausführen aus dem Projekt-Root:
    python deploy_update.py
    python deploy_update.py -m "Bugfixes und Verbesserungen"
    python deploy_update.py --no-bump        (Version nicht erhöhen)
    python deploy_update.py --no-adb         (kein Fire-Stick-Install)
    python deploy_update.py --no-github      (kein GitHub Release)

Voraussetzungen:
    pip install PyGithub python-dotenv
"""

import os
import re
import sys
import shutil
import subprocess
import tempfile
import argparse
from pathlib import Path
from dotenv import load_dotenv
from github import Github, GithubException

sys.stdout.reconfigure(encoding="utf-8")

PUBSPEC  = Path("pubspec.yaml")
APK_PATH = Path("build/app/outputs/flutter-apk/app-release.apk")
ADB      = Path(os.environ.get("LOCALAPPDATA", "")) / "Android/Sdk/platform-tools/adb.exe"
FIRESTICK_IP = "192.168.0.54:5555"


# ── Version ───────────────────────────────────────────────────────────────────

def read_version(pubspec: Path) -> tuple[int, str]:
    content = pubspec.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([^\s+]+)\+(\d+)", content, re.MULTILINE)
    if not m:
        raise ValueError("version nicht in pubspec.yaml gefunden (erwartet: 1.0.0+1).")
    return int(m.group(2)), m.group(1)


def bump_patch(pubspec: Path) -> tuple[int, str]:
    content = pubspec.read_text(encoding="utf-8")
    m = re.search(r"^(version:\s*)([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)", content, re.MULTILINE)
    if not m:
        raise ValueError("Konnte Version nicht parsen.")
    major, minor, patch, build = int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))
    new_patch  = patch + 1
    new_build  = build + 1
    new_version_name = f"{major}.{minor}.{new_patch}"
    new_line   = f"{m.group(1)}{new_version_name}+{new_build}"
    updated    = content[:m.start()] + new_line + content[m.end():]
    pubspec.write_text(updated, encoding="utf-8")
    print(f"🔢  Version:  {major}.{minor}.{patch}+{build}  →  {new_version_name}+{new_build}")
    return new_build, new_version_name


# ── Build ─────────────────────────────────────────────────────────────────────

def build_apk():
    print("🔨  Baue Release-APK …")
    result = subprocess.run("flutter build apk --release", shell=True, check=False)
    if result.returncode != 0:
        print("❌  Flutter-Build fehlgeschlagen.")
        sys.exit(1)
    print("✅  Build fertig.")


# ── ADB ───────────────────────────────────────────────────────────────────────

def adb_install():
    adb = str(ADB) if ADB.exists() else "adb"
    print(f"📡  Verbinde mit Fire Stick ({FIRESTICK_IP}) …")
    subprocess.run([adb, "connect", FIRESTICK_IP], check=False, capture_output=True)
    print("📲  Installiere APK …")
    result = subprocess.run([adb, "-s", FIRESTICK_IP, "install", "-r", str(APK_PATH)], check=False)
    if result.returncode != 0:
        print("⚠️   ADB-Install fehlgeschlagen (Fire Stick erreichbar?)")
    else:
        print("✅  Fire Stick aktualisiert.")


# ── GitHub Release ────────────────────────────────────────────────────────────

def github_release(token, username, repo_name, version_name, changelog):
    tag = f"v{version_name}"
    gh   = Github(token)
    repo = gh.get_user(username).get_repo(repo_name)

    try:
        existing = repo.get_release(tag)
        print(f"⚠️   Tag {tag} existiert bereits – wird überschrieben.")
        existing.delete_release()
        try:
            repo.get_git_ref(f"tags/{tag}").delete()
        except Exception:
            pass
    except GithubException:
        pass

    print(f"🚀  Erstelle Release {tag} …")
    release = repo.create_git_release(
        tag=tag,
        name=f"Version {version_name}",
        message=changelog,
        draft=False,
        prerelease=False,
    )

    apk_name = f"bvctv-v{version_name}.apk"
    print(f"⬆️   Lade hoch: {apk_name} …")
    with tempfile.TemporaryDirectory() as tmpdir:
        renamed = Path(tmpdir) / apk_name
        shutil.copy2(APK_PATH, renamed)
        release.upload_asset(path=str(renamed), content_type="application/vnd.android.package-archive")

    print(f"✅  GitHub Release fertig:\n   {release.html_url}")


# ── Git ───────────────────────────────────────────────────────────────────────

def git_tag(version_name: str, message: str):
    tag = f"v{version_name}"
    print(f"🏷️   Git-Commit + Tag {tag} …")
    subprocess.run(["git", "add", "-A"], check=True)
    subprocess.run(["git", "commit", "-m", f"Release {tag}: {message}"], check=False)
    subprocess.run(["git", "tag", "-f", tag, "-m", tag], check=True)
    result = subprocess.run(["git", "push", "--follow-tags"], check=False)
    if result.returncode != 0:
        subprocess.run(["git", "push"], check=False)
        subprocess.run(["git", "push", "--tags"], check=False)
    print(f"✅  Tag {tag} gepusht.")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-m", "--message",   help="Changelog (sonst automatisch generiert)")
    parser.add_argument("--no-bump",   action="store_true", help="Version nicht hochzählen")
    parser.add_argument("--no-adb",    action="store_true", help="Kein Fire-Stick-Install")
    parser.add_argument("--no-github", action="store_true", help="Kein GitHub Release")
    args = parser.parse_args()

    load_dotenv()
    token     = os.getenv("GITHUB_TOKEN")
    username  = os.getenv("GITHUB_USERNAME")
    repo_name = os.getenv("GITHUB_REPO")

    if not args.no_github and not all([token, username, repo_name]):
        print("❌  Fehlende GitHub-Zugangsdaten in .env.")
        sys.exit(1)

    if not PUBSPEC.exists():
        print(f"❌  {PUBSPEC} nicht gefunden. Script aus dem Projekt-Root ausführen.")
        sys.exit(1)

    # 1. Version
    if args.no_bump:
        version_code, version_name = read_version(PUBSPEC)
        print(f"🔢  Version:  {version_name}+{version_code}  (unverändert)")
    else:
        version_code, version_name = bump_patch(PUBSPEC)

    changelog = args.message or f"Release {version_name}"

    # 2. Git commit + tag
    git_tag(version_name, changelog)

    # 3. Build
    build_apk()

    apk_size_mb = APK_PATH.stat().st_size / 1_048_576
    print(f"📱  APK: {APK_PATH}  ({apk_size_mb:.1f} MB)")

    # 4. GitHub Release
    if not args.no_github:
        github_release(token, username, repo_name, version_name, changelog)

    # 5. ADB Install
    if not args.no_adb:
        adb_install()

    print("\n🎉  Deploy abgeschlossen!")


if __name__ == "__main__":
    main()
