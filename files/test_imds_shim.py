"""imds_shim.py の動作検証。

    python3 files/test_imds_shim.py


ECS の認証情報エンドポイントをモックして、シムが IMDS 互換の
レスポンスを返すことを確認する。
"""
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAKE_CREDS = {
    "RoleArn": "arn:aws:iam::123456789012:role/aws-to-cloudsql-task-role",
    "AccessKeyId": "ASIAFAKEFAKEFAKE",
    "SecretAccessKey": "secret-fake",
    "Token": "session-token-fake",
    "Expiration": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 6 * 3600)),
}

hits = {"count": 0}


class EcsMock(BaseHTTPRequestHandler):
    def do_GET(self):
        hits["count"] += 1
        body = json.dumps(FAKE_CREDS).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


mock = ThreadingHTTPServer(("127.0.0.1", 18170), EcsMock)
threading.Thread(target=mock.serve_forever, daemon=True).start()

os.environ["AWS_CONTAINER_CREDENTIALS_FULL_URI"] = "http://127.0.0.1:18170/creds"
os.environ["AWS_REGION"] = "ap-northeast-1"
os.environ["SHIM_PORT"] = "18169"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import imds_shim  # noqa: E402

threading.Thread(target=imds_shim.main, daemon=True).start()
time.sleep(1.0)

BASE = "http://127.0.0.1:18169"
failures = []


def check(name, actual, expected):
    ok = actual == expected
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {actual!r}")
    if not ok:
        failures.append(f"{name}: got {actual!r}, want {expected!r}")


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as r:
        return r.read().decode()


# 1. IMDSv2 セッショントークン (PUT)
req = urllib.request.Request(BASE + "/latest/api/token", method="PUT")
with urllib.request.urlopen(req, timeout=5) as r:
    check("PUT /latest/api/token", r.read().decode(), "imds-shim-session-token")

# 2. リージョン (AZ 形式で返り、末尾 1 文字を落とすとリージョンになる)
az = get("/latest/meta-data/placement/availability-zone")
check("availability-zone", az, "ap-northeast-1a")
check("derived region", az[:-1], "ap-northeast-1")

# 3. ロール名
check(
    "security-credentials",
    get("/latest/meta-data/iam/security-credentials"),
    "ecs-task-role",
)

# 4. 認証情報 (IMDS 形式)
creds = json.loads(get("/latest/meta-data/iam/security-credentials/ecs-task-role"))
check("AccessKeyId", creds["AccessKeyId"], FAKE_CREDS["AccessKeyId"])
check("SecretAccessKey", creds["SecretAccessKey"], FAKE_CREDS["SecretAccessKey"])
check("Token", creds["Token"], FAKE_CREDS["Token"])
check("Expiration", creds["Expiration"], FAKE_CREDS["Expiration"])
check("Code", creds["Code"], "Success")
check("Type", creds["Type"], "AWS-HMAC")
check("has LastUpdated", "LastUpdated" in creds, True)

# 5. キャッシュが効いていること (初回フェッチ + 上記 1 回 = ECS へは 1 回のみ)
for _ in range(5):
    get("/latest/meta-data/iam/security-credentials/ecs-task-role")
check("ECS endpoint hits (cached)", hits["count"], 1)

# 6. キャッシュ失効後は取り直すこと
imds_shim._cache["fetched_at"] = 0
get("/latest/meta-data/iam/security-credentials/ecs-task-role")
check("ECS endpoint hits (after expiry)", hits["count"], 2)

# 6b. 有効期限が近い認証情報はキャッシュされないこと
FAKE_CREDS["Expiration"] = time.strftime(
    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 60)
)
imds_shim._cache["fetched_at"] = 0
get("/latest/meta-data/iam/security-credentials/ecs-task-role")  # 期限間近をキャッシュ
before = hits["count"]
get("/latest/meta-data/iam/security-credentials/ecs-task-role")  # 再取得されるはず
check("refetch when expiring soon", hits["count"], before + 1)

# 7. 未知のパスは 404
try:
    get("/nope")
    check("unknown path -> 404", "200", "404")
except urllib.error.HTTPError as e:
    check("unknown path -> 404", e.code, 404)

print()
if failures:
    print(f"{len(failures)} FAILURE(S)")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("ALL CHECKS PASSED")
