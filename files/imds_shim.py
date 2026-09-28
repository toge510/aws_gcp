#!/usr/bin/env python3
"""EC2 IMDS 互換シム (ECS Fargate 用)

GCP の認証ライブラリは Workload Identity 連携の AWS 認証情報を
EC2 IMDS (169.254.169.254) からのみ取得する実装になっており、
ECS タスクの認証情報エンドポイント (169.254.170.2) を認識しない。
  https://github.com/googleapis/google-cloud-go/issues/13479

起動時に AWS_ACCESS_KEY_ID などへ展開する回避策が広く使われているが、
ECS タスクロールの認証情報は約 6 時間で失効するため、常駐プロセスでは
失効後に STS トークン交換が失敗する。

そこでこのシムが IMDS 互換のエンドポイントを 127.0.0.1 に公開し、
問い合わせのたびに ECS のエンドポイントから新鮮な認証情報を取得して
返す。Cloud SQL Auth Proxy 側は credential_source の URL をこのシムに
向けるだけでよく、認証情報は常に自動更新される。

標準ライブラリのみで動作する (依存パッケージなし)。
"""

import calendar
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("SHIM_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SHIM_PORT", "8169"))

# IMDS は「ロール名の一覧」→「ロール名ごとの認証情報」の 2 段構成なので
# 任意の固定名を返す。実際の認証情報は ECS 側が決めるため名前は何でもよい。
ROLE_NAME = "ecs-task-role"

ECS_ENDPOINT_BASE = "http://169.254.170.2"

# 同一の認証情報を短時間に何度も取りに行かないための簡易キャッシュ。
# TTL を過ぎた場合と、有効期限の 5 分前を過ぎた場合は取り直す。
_CACHE_LOCK = threading.Lock()
_cache = {"creds": None, "fetched_at": 0.0}
_CACHE_TTL_SECONDS = 300
_EXPIRY_MARGIN_SECONDS = 300


def _log(message):
    print(f"[imds-shim] {message}", file=sys.stderr, flush=True)


def _ecs_credentials_url():
    """ECS タスクの認証情報エンドポイント URL を環境変数から組み立てる。"""
    full_uri = os.environ.get("AWS_CONTAINER_CREDENTIALS_FULL_URI")
    if full_uri:
        return full_uri

    relative_uri = os.environ.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
    if relative_uri:
        return ECS_ENDPOINT_BASE + relative_uri

    raise RuntimeError(
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI / _FULL_URI が未設定です。"
        " ECS タスクとして実行されていますか?"
    )


def _expires_soon(credentials):
    """認証情報の有効期限が近い (あるいは不明) かどうか。"""
    expiration = credentials.get("Expiration")
    if not expiration:
        return True
    try:
        # 例: "2026-09-29T05:00:00Z"
        expires_at = calendar.timegm(time.strptime(expiration, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        # 想定外の書式なら安全側に倒して取り直す
        return True
    return expires_at - time.time() < _EXPIRY_MARGIN_SECONDS


def fetch_credentials():
    """ECS から一時認証情報を取得する。レスポンスは IMDS と同じキー名。"""
    with _CACHE_LOCK:
        cached = _cache["creds"]
        fresh = time.time() - _cache["fetched_at"] < _CACHE_TTL_SECONDS
        if cached is not None and fresh and not _expires_soon(cached):
            return cached

    request = urllib.request.Request(_ecs_credentials_url())

    # EKS Pod Identity など、認可トークンを要求する構成にも対応しておく
    auth_token = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN")
    token_file = os.environ.get("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE")
    if not auth_token and token_file:
        with open(token_file, encoding="utf-8") as handle:
            auth_token = handle.read().strip()
    if auth_token:
        request.add_header("Authorization", auth_token)

    with urllib.request.urlopen(request, timeout=5) as response:
        credentials = json.load(response)

    with _CACHE_LOCK:
        _cache["creds"] = credentials
        _cache["fetched_at"] = time.time()

    return credentials


class ImdsHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _respond(self, status, body, content_type="text/plain"):
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_PUT(self):  # noqa: N802 (BaseHTTPRequestHandler の命名規約)
        """IMDSv2 のセッショントークン要求。値は検証されないのでダミーを返す。"""
        if self.path.split("?")[0] == "/latest/api/token":
            self._respond(200, "imds-shim-session-token")
        else:
            self._respond(404, "not found")

    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0]

        if path == "/latest/api/token":
            self._respond(200, "imds-shim-session-token")
            return

        if path == "/latest/meta-data/placement/availability-zone":
            # GCP の認証ライブラリは末尾 1 文字を落としてリージョンとして扱う
            region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
            if not region:
                self._respond(500, "AWS_REGION is not set")
                return
            self._respond(200, f"{region}a")
            return

        if path == "/latest/meta-data/iam/security-credentials":
            self._respond(200, ROLE_NAME)
            return

        if path == f"/latest/meta-data/iam/security-credentials/{ROLE_NAME}":
            try:
                credentials = fetch_credentials()
            except Exception as error:  # noqa: BLE001 (原因を問わず 500 で返す)
                _log(f"failed to fetch ECS credentials: {error!r}")
                self._respond(500, "failed to fetch ECS credentials")
                return

            self._respond(
                200,
                json.dumps(
                    {
                        "Code": "Success",
                        "Type": "AWS-HMAC",
                        "LastUpdated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "AccessKeyId": credentials["AccessKeyId"],
                        "SecretAccessKey": credentials["SecretAccessKey"],
                        "Token": credentials["Token"],
                        "Expiration": credentials["Expiration"],
                    }
                ),
                content_type="application/json",
            )
            return

        self._respond(404, "not found")

    def log_message(self, fmt, *args):
        # アクセスログは冗長なので抑制する (エラーは _log で出力)
        pass


def main():
    # 起動直後に一度取得し、設定ミスを早期に検出する
    try:
        fetch_credentials()
        _log("successfully fetched ECS task credentials")
    except Exception as error:  # noqa: BLE001
        _log(f"WARNING: initial credential fetch failed: {error!r}")

    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ImdsHandler)
    _log(f"listening on http://{LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
