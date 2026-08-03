#!/usr/bin/env python3
"""
deploy_update.py – Vollständiger Deploy-Pipeline für BVCTV.

Was das Script macht (automatisch, ohne Rückfragen):
  1. Patch-Version in pubspec.yaml hochzählen  (z.B. 1.0.0+1 → 1.0.1+2)
  2. Flutter Release-APKs bauen — standardmäßig BEIDE Varianten:
       bvc     → bvctv-v<version>.apk          (Vereins-Build, alle Quellen)
       neutral → bvctv-neutral-v<version>.apk  (nur VBTV, kein Vereinsbezug)
  3. GitHub Release erstellen und beide APKs hochladen
  4. Eine Variante per ADB auf den Fire Stick installieren (192.168.0.54:5555)

Beide Varianten kommen aus DEMSELBEN Code (lib/app_variant.dart, gesteuert per
--dart-define=VARIANT). Jede Funktionsänderung landet damit automatisch in
beiden Builds — es gibt keinen Fork und keinen zweiten Branch zu pflegen.

Ausführen aus dem Projekt-Root:
    python deploy_update.py
    python deploy_update.py -m "Bugfixes und Verbesserungen"
    python deploy_update.py --no-bump           (Version nicht erhöhen)
    python deploy_update.py --no-adb            (kein Fire-Stick-Install)
    python deploy_update.py --no-github         (kein GitHub Release)
    python deploy_update.py --variant neutral   (nur die neutrale Variante bauen)
    python deploy_update.py --install neutral   (neutrale Variante auf den Fire Stick)

Voraussetzungen:
    pip install PyGithub python-dotenv
"""

import os
import re
import sys
import shutil
import subprocess
import argparse
from pathlib import Path
from dotenv import load_dotenv
from github import Github, GithubException

sys.stdout.reconfigure(encoding="utf-8")

PUBSPEC  = Path("pubspec.yaml")
APK_PATH = Path("build/app/outputs/flutter-apk/app-release.apk")
DIST_DIR = Path("build/dist")
ADB      = Path(os.environ.get("LOCALAPPDATA", "")) / "Android/Sdk/platform-tools/adb.exe"
FIRESTICK_IP = "192.168.0.54:5555"

# Build-Varianten aus EINEM Codestand (siehe lib/app_variant.dart).
#   bvc     – die normale App mit Vereins-Branding, Laola1 + GBT
#   neutral – nur VBTV, keine Source-Chips, kein Vereinsbezug (fuer Tester)
# Jede Funktionsaenderung landet automatisch in beiden Builds; es gibt
# bewusst keinen Fork und keinen zweiten Branch.
#
# Das asset_prefix MUSS zu AppVariant.updateAssetPrefix passen — daran
# erkennt der In-App-Updater sein eigenes APK am gemeinsamen Release.
VARIANTS = {
    "bvc":     {"args": [],                                "asset_prefix": "bvctv-v"},
    "neutral": {"args": ["--dart-define=VARIANT=neutral"], "asset_prefix": "bvctv-neutral-v"},
}
DEFAULT_INSTALL_VARIANT = "bvc"


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

def build_apk(variant: str, version_name: str) -> Path:
    """Baut eine Variante und legt das APK unter seinem finalen Release-Namen
    in build/dist ab. Noetig, weil Flutter jede Variante an denselben Pfad
    schreibt — ohne Umkopieren wuerde der zweite Build den ersten ueberbuegeln.
    """
    cfg = VARIANTS[variant]
    cmd = " ".join(["flutter", "build", "apk", "--release"] + cfg["args"])
    print(f"🔨  Baue Release-APK [{variant}] …")
    result = subprocess.run(cmd, shell=True, check=False)
    if result.returncode != 0:
        print(f"❌  Flutter-Build [{variant}] fehlgeschlagen.")
        sys.exit(1)

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    target = DIST_DIR / f"{cfg['asset_prefix']}{version_name}.apk"
    if target.exists():
        target.unlink()
    shutil.copy2(APK_PATH, target)
    size_mb = target.stat().st_size / 1_048_576
    print(f"✅  Build [{variant}] fertig: {target}  ({size_mb:.1f} MB)")
    return target


# ── ADB ───────────────────────────────────────────────────────────────────────

def adb_install(apk: Path, variant: str):
    adb = str(ADB) if ADB.exists() else "adb"
    print(f"📡  Verbinde mit Fire Stick ({FIRESTICK_IP}) …")
    subprocess.run([adb, "connect", FIRESTICK_IP], check=False, capture_output=True)
    # Beide Varianten teilen sich die applicationId — eine Installation
    # ersetzt also die andere auf demselben Geraet.
    print(f"📲  Installiere APK [{variant}] …")
    result = subprocess.run([adb, "-s", FIRESTICK_IP, "install", "-r", str(apk)], check=False)
    if result.returncode != 0:
        print("⚠️   ADB-Install fehlgeschlagen (Fire Stick erreichbar?)")
    else:
        print("✅  Fire Stick aktualisiert.")


# ── GitHub Release ────────────────────────────────────────────────────────────

def github_release(token, username, repo_name, version_name, changelog, apks):
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

    # Alle gebauten Varianten an dasselbe Release haengen. Der In-App-Updater
    # sucht sich anhand des Dateinamen-Praefix sein eigenes APK heraus.
    for variant, apk in apks.items():
        print(f"⬆️   Lade hoch: {apk.name}  [{variant}] …")
        release.upload_asset(
            path=str(apk),
            content_type="application/vnd.android.package-archive")

    print(f"✅  GitHub Release fertig:\n   {release.html_url}")


# ── Git ───────────────────────────────────────────────────────────────────────

def git_tag(version_name: str, message: str):
    tag = f"v{version_name}"
    print(f"🏷️   Git-Commit + Tag {tag} …")
    subprocess.run(["git", "add", "-A"], check=True)
    subprocess.run(["git", "commit", "-m", f"Release {tag}: {message}"], check=False)
    subprocess.run(["git", "tag", "-f", tag, "-m", tag], check=True)
    result = subprocess.run(["git", "push", "--set-upstream", "origin", "main", "--follow-tags"], check=False)
    if result.returncode != 0:
        subprocess.run(["git", "push", "--tags"], check=False)
    print(f"✅  Tag {tag} gepusht.")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-m", "--message",   help="Changelog (sonst automatisch generiert)")
    parser.add_argument("--no-bump",   action="store_true", help="Version nicht hochzählen")
    parser.add_argument("--no-adb",    action="store_true", help="Kein Fire-Stick-Install")
    parser.add_argument("--no-github", action="store_true", help="Kein GitHub Release")
    parser.add_argument("--variant", default="both",
                        choices=["both"] + list(VARIANTS),
                        help="Welche Build-Variante(n): both (Standard), bvc, neutral")
    parser.add_argument("--install", default=DEFAULT_INSTALL_VARIANT,
                        choices=list(VARIANTS),
                        help="Welche Variante per ADB auf den Fire Stick geht")
    args = parser.parse_args()

    variants = list(VARIANTS) if args.variant == "both" else [args.variant]

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

    # 3. Build — jede angeforderte Variante einzeln
    apks = {v: build_apk(v, version_name) for v in variants}

    # 4. GitHub Release
    if not args.no_github:
        github_release(token, username, repo_name, version_name, changelog, apks)

    # 5. ADB Install — nur die gewaehlte Variante (beide teilen sich die
    #    applicationId, es kann immer nur eine auf dem Geraet sein).
    if not args.no_adb:
        install_variant = args.install if args.install in apks else next(iter(apks))
        adb_install(apks[install_variant], install_variant)

    print("\n🎉  Deploy abgeschlossen!")


if __name__ == "__main__":
    main()
