#!/usr/bin/env python3
"""
check_playlists.py
Loggt sich per PKCE bei volleyballworld.com ein, dann prüft alle 25 Playlists
auf Videos >2h und YouTube-Links.
"""
import asyncio, base64, hashlib, json, secrets, urllib.parse, urllib.request
from playwright.async_api import async_playwright

CLIENT_ID    = '93d30c71-8a06-46c3-a288-dfb48f082313'
REDIRECT_URI = 'https://tv.volleyballworld.com/api/oauth'
AUTH_EP      = 'https://signin.volleyballworld.com/service/oidc/vbtv-web/authorize'
TOKEN_EP     = 'https://signin.volleyballworld.com/api/oidc/vbtv-web/token'
JW_BASE      = 'https://zapp-5434-volleyball-tv.web.app/jw'
ORIGIN       = 'https://tv.volleyballworld.com'
PLAYLIST_IDS = [
    'SSY67gLR','cPYPpGbh','QN15YAsv','XtDifda1','Alnlc8y6',
    '7YDTRD4b','Yibt33ZH','VxBoIqbh','yh8E63fL','r4AqXHZL',
    'JHc8IvNp','RdBjPvMi','XKf1RgNI','i4Jy9iXv','4M0l7Maq',
    '1I6kfBOF','4I8f0C5c','kA1vhOgD','hD9vHBp7','w9bGTNS7',
    '0o8WjoXX','jO0cOwrg','fkLgV9W0','Cz0AlBEM','rzkJI4NX',
]

def _verifier():
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b'=').decode()

def _challenge(v):
    return base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()

async def login() -> str:
    verifier  = _verifier()
    auth_url  = AUTH_EP + '?' + urllib.parse.urlencode({
        'response_type': 'code', 'client_id': CLIENT_ID,
        'redirect_uri': REDIRECT_URI, 'scope': 'openid email profile',
        'code_challenge': _challenge(verifier), 'code_challenge_method': 'S256',
        'prompt': 'login', 'workflow': 'fulljitflow_v3_fast',
    })
    code_event = asyncio.Event()
    auth_code  = {}

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        page    = await browser.new_page()

        async def intercept(route, request):
            url = request.url
            if url.startswith(REDIRECT_URI):
                qs = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
                if 'code' in qs:
                    auth_code['code'] = qs['code'][0]
                    code_event.set()
                await route.abort()
                return
            await route.continue_()

        await page.route('**', intercept)
        await page.goto(auth_url)
        print("Bitte einloggen …")
        await code_event.wait()
        await browser.close()

    code = auth_code.get('code')
    if not code:
        raise RuntimeError("Kein Auth-Code erhalten.")

    data = urllib.parse.urlencode({
        'grant_type': 'authorization_code', 'client_id': CLIENT_ID,
        'redirect_uri': REDIRECT_URI, 'code': code, 'code_verifier': verifier,
    }).encode()
    req = urllib.request.Request(TOKEN_EP, data=data, method='POST')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())['access_token']

def fetch_playlist(pid: str, ctx: str) -> dict | None:
    url = f'{JW_BASE}/playlists/{pid}?overrideFeedType=moreinfo&ctx={ctx}'
    req = urllib.request.Request(url, headers={'Origin': ORIGIN})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"   HTTP {e.code}: {e.read()[:120]}")
        return None
    except Exception as e:
        print(f"   ERR: {e}")
        return None

def build_ctx(token: str) -> str:
    # Compact JSON (no spaces) + no base64 padding — matches Dart's base64Url.encode(utf8.encode(jsonEncode(...)))
    payload = json.dumps(
        {'quick-bricky-login-flow.access_token': token, 'platform': 'web'},
        separators=(',', ':')
    )
    return base64.urlsafe_b64encode(payload.encode()).rstrip(b'=').decode()

TOKEN_CACHE = 'check_token.txt'

async def main():
    print("=== BVCTV Playlist-Check ===\n")
    import os
    if os.path.exists(TOKEN_CACHE):
        with open(TOKEN_CACHE) as f:
            token = f.read().strip()
        print("Cached token used.\n")
    else:
        token = await login()
        with open(TOKEN_CACHE, 'w') as f:
            f.write(token)
        print("Token erhalten!\n")
    ctx = build_ctx(token)

    for pid in PLAYLIST_IDS:
        data = fetch_playlist(pid, ctx)
        if data is None:
            print(f"{pid} | FEHLER")
            continue
        entries   = data.get('entry') or []
        title     = data.get('title', '?')
        long_vids = [e for e in entries if isinstance(e.get('extensions', {}).get('duration'), (int, float)) and e['extensions']['duration'] > 7200]
        yt_links  = [e for e in entries if e.get('extensions', {}).get('contentType') == 'link']
        flag = ' ***' if (long_vids or yt_links) else ''
        print(f"{pid} | {len(entries):3d} entries | >2h: {len(long_vids)} | YT: {len(yt_links)} | {title}{flag}")
        for e in long_vids:
            h = round(e['extensions']['duration'] / 3600, 1)
            print(f"   LONG [{e['extensions'].get('event_state','')}] {h}h | {e.get('title','')}")
        for e in yt_links:
            print(f"   YT   {e.get('title','')} -> {e.get('extensions',{}).get('linkUrl','')}")

asyncio.run(main())
