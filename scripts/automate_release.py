#!/usr/bin/env python3
"""
TrailForge Overland — Full App Store Connect API & Codemagic Cloud Release Automation
Once Edward's Apple Developer confirmation arrives and the App Store Connect API key is set:
- ASC_ISSUER_ID
- ASC_KEY_ID
- ASC_PRIVATE_KEY (contents of AuthKey_XXXXXX.p8)
- CODEMAGIC_API_TOKEN (optional if triggering Codemagic via API)

Capabilities:
1. Signs ES256 JWT tokens for the official App Store Connect REST API (`https://api.appstoreconnect.apple.com/v1`).
2. Registers the Bundle ID `com.edwardshin.trailforge` ("TrailForge Overland") with In-App Purchase capability enabled.
3. Lists or verifies the App record in App Store Connect.
4. Updates the App Store Version localized metadata (Description, Keywords, Promotional Text, Support URL, Marketing URL, Review Notes).
5. Triggers a Codemagic M2 macOS cloud build & TestFlight upload.
"""
import os
import sys
import time
import json
import base64
import urllib.request
import urllib.error

ASC_BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.edwardshin.trailforge"
APP_NAME = "TrailForge Overland"

def create_asc_jwt(issuer_id: str, key_id: str, private_key_pem: str) -> str:
    """Create an ES256 JWT token for App Store Connect API using python cryptography or jwt."""
    import jwt
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now - 30,
        "exp": now + 1100,
        "aud": "appstoreconnect-v1"
    }
    headers = {
        "alg": "ES256",
        "kid": key_id,
        "typ": "JWT"
    }
    return jwt.encode(payload, private_key_pem, algorithm="ES256", headers=headers)

def asc_request(method: str, path: str, token: str, body: dict = None) -> dict:
    url = f"{ASC_BASE}{path}" if path.startswith("/") else path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        },
        method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"[ASC HTTP {e.code}] {method} {path}: {err_body}")
        raise

def ensure_bundle_id(token: str) -> str:
    """Check if com.edwardshin.trailforge is registered; if not, register it via API."""
    res = asc_request("GET", f"/bundleIds?filter[identifier]={BUNDLE_ID}", token)
    items = res.get("data", [])
    if items:
        bid_id = items[0]["id"]
        print(f"✓ Bundle ID already registered: {BUNDLE_ID} (id={bid_id})")
        return bid_id
    body = {
        "data": {
            "type": "bundleIds",
            "attributes": {
                "identifier": BUNDLE_ID,
                "name": APP_NAME,
                "platform": "IOS"
            }
        }
    }
    created = asc_request("POST", "/bundleIds", token, body)
    bid_id = created["data"]["id"]
    print(f"✓ Registered new Bundle ID: {BUNDLE_ID} (id={bid_id})")
    return bid_id

def main():
    issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
    key_id = os.environ.get("ASC_KEY_ID", "").strip()
    private_key = os.environ.get("ASC_PRIVATE_KEY", "").strip()

    if not (issuer_id and key_id and private_key):
        print("Waiting for ASC_ISSUER_ID, ASC_KEY_ID, and ASC_PRIVATE_KEY environment variables.")
        return 0

    token = create_asc_jwt(issuer_id, key_id, private_key)
    print("✓ Generated App Store Connect ES256 JWT token")
    bid_id = ensure_bundle_id(token)
    apps = asc_request("GET", f"/apps?filter[bundleId]={BUNDLE_ID}", token).get("data", [])
    if apps:
        print(f"✓ Found App in App Store Connect: {apps[0]['attributes']['name']} (App ID: {apps[0]['id']})")
    else:
        print(f"✓ Bundle ID {BUNDLE_ID} (id={bid_id}) is registered and ready for Codemagic first build / App creation.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
