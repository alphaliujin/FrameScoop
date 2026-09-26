#!/usr/bin/env python3
#
# asc_builds.py
# 查询 App Store Connect 上本应用的构建列表与处理状态。
#
# 为什么要它：本版 Xcode 的 altool 没有 --list-builds；上传 .pkg 后要确认构建是否
#   处理完成（processingState=VALID 才能在版本页被选中提交审核），只能走 ASC API。
#
# 用法:
#   python3 Scripts/asc_builds.py
#   python3 Scripts/asc_builds.py --limit 10
#
# 前置条件：ASC API Key 私钥位于 ~/private_keys/AuthKey_<KEY_ID>.p8
#   可用环境变量覆盖：ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH / ASC_BUNDLE_ID
#
# 实现要点：JWT 的 ES256 签名要的是 64 字节 raw(r||s)，而 openssl 输出 DER，
#   必须转换后再 base64url 拼接 —— 直接塞 DER 会被 ASC 回 401，且报错完全不提是
#   签名格式的问题。另外 builds.version 是 **build 号**不是市场版本号，要读
#   preReleaseVersion.version 才知道它挂在哪个版本下。
#
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime

API = "https://api.appstoreconnect.apple.com"
KEY_ID = os.environ.get("ASC_KEY_ID", "58Q6QDW4RW")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "f44fc55d-9307-4901-9708-c53e91164a0c")
KEY_PATH = os.path.expanduser(
    os.environ.get("ASC_KEY_PATH", "~/private_keys/AuthKey_%s.p8" % KEY_ID)
)
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "com.framescoop.app")


def b64u(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def read_der_len(buf, i):
    """读 DER 长度字段，返回 (长度, 下一个位置)。支持长短两种格式。"""
    ln = buf[i]
    i += 1
    if ln & 0x80:
        n = ln & 0x7F
        ln = int.from_bytes(buf[i : i + n], "big")
        i += n
    return ln, i


def der_to_raw(der):
    """ECDSA DER(SEQUENCE{INTEGER r, INTEGER s}) -> 64 字节 raw(r||s)。"""
    if der[0] != 0x30:
        raise ValueError("签名不是 DER SEQUENCE")
    _, i = read_der_len(der, 1)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("签名里不是 DER INTEGER")
        ln, i = read_der_len(der, i + 1)
        parts.append(der[i : i + ln].lstrip(b"\x00").rjust(32, b"\x00"))
        i += ln
    return parts[0] + parts[1]


def make_token():
    if not os.path.exists(KEY_PATH):
        sys.exit("找不到 API Key 私钥: %s" % KEY_PATH)
    now = int(time.time())
    header = {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    payload = {"iss": ISSUER_ID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing_input = "%s.%s" % (
        b64u(json.dumps(header, separators=(",", ":")).encode()),
        b64u(json.dumps(payload, separators=(",", ":")).encode()),
    )
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "signing_input")
        sig = os.path.join(d, "sig.der")
        with open(src, "w") as f:
            f.write(signing_input)
        r = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", KEY_PATH, "-out", sig, src],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            sys.exit("openssl 签名失败: %s" % r.stderr.strip())
        with open(sig, "rb") as f:
            der = f.read()
    return "%s.%s" % (signing_input, b64u(der_to_raw(der)))


def api(path, token):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            errors = json.loads(body).get("errors", [])
            body = "; ".join(x.get("detail", "") for x in errors) or body
        except ValueError:
            pass
        sys.exit("ASC API %s 返回 %s: %s" % (path.split("?")[0], e.code, body.strip()))
    except urllib.error.URLError as e:
        sys.exit("连不上 ASC API: %s" % e.reason)


def local_time(ts):
    """转成本机时区，便于和「我刚上传的时间」对照。"""
    if not ts:
        return "-"
    try:
        return datetime.fromisoformat(ts).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ts


def main():
    parser = argparse.ArgumentParser(description="查询 App Store Connect 构建状态")
    parser.add_argument("--limit", type=int, default=6, help="列出最近多少个构建（默认 6）")
    args = parser.parse_args()

    token = make_token()
    apps = api(
        "/v1/apps?filter%%5BbundleId%%5D=%s&fields%%5Bapps%%5D=name,bundleId" % BUNDLE_ID,
        token,
    )
    if not apps["data"]:
        sys.exit("ASC 里没有 bundle id = %s 的应用记录" % BUNDLE_ID)
    app = apps["data"][0]
    print("应用: %s (%s)\n" % (app["attributes"]["name"], app["attributes"]["bundleId"]))

    builds = api(
        "/v1/builds?filter%%5Bapp%%5D=%s&sort=-uploadedDate&limit=%d"
        "&include=preReleaseVersion"
        "&fields%%5Bbuilds%%5D=version,processingState,uploadedDate,expired,preReleaseVersion"
        % (app["id"], args.limit),
        token,
    )
    pre = {i["id"]: i["attributes"] for i in builds.get("included", [])}

    print("%-6s %-10s %-17s %-9s %s" % ("build", "状态", "上传时间(本地)", "归属版本", "备注"))
    for b in builds["data"]:
        a = b["attributes"]
        rel = (b["relationships"].get("preReleaseVersion") or {}).get("data") or {}
        note = "已过期" if a.get("expired") else ""
        if a.get("processingState") == "VALID":
            note = (note + " 可在版本页选中").strip()
        print(
            "%-6s %-10s %-17s %-9s %s"
            % (
                a.get("version"),
                a.get("processingState"),
                local_time(a.get("uploadedDate")),
                pre.get(rel.get("id"), {}).get("version", "?"),
                note,
            )
        )
    print("\n注：build 列是 build 号，不是市场版本号；「归属版本」列才是 1.0.x。")


if __name__ == "__main__":
    main()
