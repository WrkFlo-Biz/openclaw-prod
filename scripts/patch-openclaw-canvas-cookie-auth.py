#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys


def patch_file(path: pathlib.Path, cookie_name: str) -> bool:
    s = path.read_text(encoding="utf-8")

    # Only patch the gateway bundle(s) that actually implement canvas auth.
    if "async function authorizeCanvasRequest(params)" not in s:
        return False
    if cookie_name in s:
        print(f"openclaw canvas cookie auth: skip {path}")
        return False

    needle = "let lastAuthFailure = null;\n\tconst token = getBearerToken(req);"
    if needle not in s:
        print(f"openclaw canvas cookie auth: needle not found in {path}; skipping")
        return False

    cookie_patch = "\n".join(
        [
            "let lastAuthFailure = null;",
            "\tlet token = getBearerToken(req);",
            "\tif (!token) {",
            "\t\tconst cookie = getHeader(req, \"cookie\") ?? \"\";",
            f"\t\tconst m = cookie.match(/(?:^|;\\s*){cookie_name}=([^;]+)/);",
            "\t\tif (m) {",
            "\t\t\ttry { token = decodeURIComponent(m[1]); } catch { token = m[1]; }",
            "\t\t}",
            "\t}",
        ]
    )

    s = s.replace(needle, cookie_patch, 1)

    # Insert a one-time login flow: ?token=<gateway token> -> Set-Cookie + redirect without token.
    m = re.search(
        r"if \(isCanvasPath\(requestPath\)\) \{\n(?P<indent>\t+)const ok = await authorizeCanvasRequest",
        s,
    )
    if not m:
        print(f"openclaw canvas cookie auth: canvas auth block not found in {path}; skipping")
        return False
    indent = m.group("indent")

    insert_lines = [
        f'{indent}const canvasUrl = new URL(req.url ?? "/", "http://localhost");',
        f'{indent}const queryToken = canvasUrl.searchParams.get("token")?.trim();',
        f"{indent}if (queryToken) {{",
        f"{indent}\tconst authResult = await authorizeGatewayConnect({{",
        f"{indent}\t\tauth: {{ ...resolvedAuth, allowTailscale: false }},",
        f"{indent}\t\tconnectAuth: {{ token: queryToken, password: queryToken }},",
        f"{indent}\t\treq,",
        f"{indent}\t\ttrustedProxies,",
        f"{indent}\t\trateLimiter",
        f"{indent}\t}});",
        f"{indent}\tif (!authResult.ok) {{",
        f"{indent}\t\tsendGatewayAuthFailure(res, authResult);",
        f"{indent}\t\treturn;",
        f"{indent}\t}}",
        f'{indent}\tres.setHeader("Set-Cookie", "{cookie_name}=" + encodeURIComponent(queryToken) + "; Path=/__openclaw__/; HttpOnly; Secure; SameSite=Lax");',
        f'{indent}\tcanvasUrl.searchParams.delete("token");',
        f"{indent}\tconst qs = canvasUrl.searchParams.toString();",
        f"{indent}\tres.statusCode = 302;",
        f'{indent}\tres.setHeader("Cache-Control", "no-store");',
        f'{indent}\tres.setHeader("Location", canvasUrl.pathname + (qs ? "?" + qs : ""));',
        f"{indent}\tres.end();",
        f"{indent}\treturn;",
        f"{indent}}}",
    ]
    insert = "\n".join(insert_lines) + "\n"

    needle2 = f"\n{indent}const ok = await authorizeCanvasRequest"
    if needle2 not in s:
        print(f"openclaw canvas cookie auth: callsite not found in {path}; skipping")
        return False

    s = s.replace(needle2, "\n" + insert + indent + "const ok = await authorizeCanvasRequest", 1)

    path.write_text(s, encoding="utf-8")
    print(f"openclaw canvas cookie auth: patched {path}")
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-openclaw-canvas-cookie-auth.py <openclaw-dist-dir>", file=sys.stderr)
        return 2

    dist_dir = pathlib.Path(sys.argv[1])
    if not dist_dir.is_dir():
        print(f"dist dir not found: {dist_dir}", file=sys.stderr)
        return 2

    cookie_name = "openclaw_canvas_token"

    candidates = sorted(dist_dir.glob("gateway-cli-*.js"))
    if not candidates:
        # No gateway bundle (unexpected), but don't fail the whole build.
        print(f"openclaw canvas cookie auth: no gateway-cli bundle files under {dist_dir}")
        return 0

    found_target = False
    patched_any = False
    for f in candidates:
        text = f.read_text(encoding="utf-8")
        if "async function authorizeCanvasRequest(params)" not in text:
            continue
        found_target = True
        # Re-read inside patch_file (keeps logic centralized).
        patched_any = patch_file(f, cookie_name) or patched_any

    if not found_target:
        print("openclaw canvas cookie auth: no authorizeCanvasRequest found; skipping")
        return 0

    if not patched_any:
        print("openclaw canvas cookie auth: nothing patched (already applied?)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

