#!/usr/bin/env python3
"""cmux notification hook -> ntfy push with full context.

cmux runs this for every notification it posts (see
~/.config/cmux/cmux.json -> notifications.hooks). It receives the
notification policy JSON on stdin and must return the (possibly updated)
policy on stdout. We forward a rich message to ntfy and return the policy
byte-for-byte unchanged, so cmux's own behaviour is untouched.

Why a hook and not the relay's event stream: cmux REDACTS notification
text in the event stream (payload.title/body are null with only
title_length/body_length and redacted_fields exposed), so a stream
consumer can never see the real message. The hook gets the real
title/subtitle/body plus agent context.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request

NTFY_SERVER = os.environ.get("CMUX_NTFY_SERVER", "https://ntfy.sh")
# Private topic: the name is the only credential (anyone who knows it can
# read/post), so treat it like a password.
NTFY_TOPIC = os.environ.get("CMUX_NTFY_TOPIC", "cmux-relay-iAQoajyMynDzmqT74sKKQgtN")
NTFY_TOKEN = os.environ.get("CMUX_NTFY_TOKEN", "")
CMUX_BIN = "/Applications/cmux.app/Contents/Resources/bin/cmux"
TREE_TIMEOUT_S = 2.0
HTTP_TIMEOUT_S = 4.0

# Category -> (label, tag, priority 1..5)
CATEGORY_STYLE = {
    "needs-permission": ("needs your input", "warning", 4),
    "turn-complete": ("turn complete", "white_check_mark", 3),
    "idle-reminder": ("idle", "hourglass", 2),
}


def resolve_names(workspace_id: str | None, surface_id: str | None) -> tuple[str, str]:
    """UUID -> human titles via `cmux tree --json`. Bounded by a hard
    timeout: if cmux's socket is busy (e.g. it is waiting on this very
    hook), fall back to the raw ids rather than stall the notification."""
    if not workspace_id and not surface_id:
        return "", ""
    try:
        out = subprocess.run(
            [CMUX_BIN, "tree", "--all", "--id-format", "uuids", "--json"],
            capture_output=True, text=True, timeout=TREE_TIMEOUT_S,
        )
        doc = json.loads(out.stdout)
    except Exception:
        return str(workspace_id or ""), str(surface_id or "")

    ws_title = sf_title = ""
    for window in doc.get("windows", []):
        for ws in window.get("workspaces", []):
            if ws.get("id") == workspace_id:
                ws_title = ws.get("title") or ""
            for pane in ws.get("panes", []):
                for surface in pane.get("surfaces", []):
                    if surface.get("id") == surface_id:
                        sf_title = surface.get("title") or ""
    return ws_title, sf_title


def main() -> None:
    raw = sys.stdin.read()

    # Return the policy unchanged FIRST, so cmux is never blocked on us.
    sys.stdout.write(raw)
    sys.stdout.flush()

    if not NTFY_TOPIC:
        return

    try:
        doc = json.loads(raw)
    except Exception:
        return

    note = doc.get("notification") or {}
    ctx = doc.get("context") or {}
    agent = doc.get("agent") or {}

    title = (note.get("title") or "").strip()
    subtitle = (note.get("subtitle") or "").strip()
    body = (note.get("body") or "").strip()
    ws_id = note.get("workspaceId")
    sf_id = note.get("surfaceId")
    cwd = (ctx.get("cwd") or "").strip()

    kind = (agent.get("kind") or "").strip()
    category = (agent.get("category") or "").strip()
    is_subagent = bool(agent.get("isSubagent"))
    pending = agent.get("pending")

    # Subagent turn-completes are noise (omp fans out many). Keep their
    # permission requests, drop their completions.
    if is_subagent and category == "turn-complete":
        return

    ws_title, sf_title = resolve_names(ws_id, sf_id)
    label, tag, priority = CATEGORY_STYLE.get(category, ("", "computer", 3))

    # --- compose the push ---
    head = title or (kind.title() if kind else "cmux")
    if category == "needs-permission":
        head = f"⚠ {head}" if not head.startswith("⚠") else head

    lines: list[str] = []
    if label:
        lines.append(f"[{label}]" + (f" {kind}" if kind else ""))
    if subtitle and subtitle != body and subtitle.lower() != kind.lower():
        lines.append(subtitle)
    if body and body != title:
        lines.append(body)
    if pending:
        lines.append("(background work still running)")

    where = " › ".join(p for p in (ws_title, sf_title) if p)
    if where:
        lines.append("")
        lines.append(f"space: {where}")
    if cwd:
        lines.append(f"cwd: {cwd}")

    message = "\n".join(lines).strip() or head

    deeplink = ""
    if sf_id:
        deeplink = f"cmux://surface/{sf_id}"
        if ws_id:
            deeplink += f"?workspace={ws_id}"

    payload: dict[str, object] = {
        "topic": NTFY_TOPIC,
        "title": head,
        "message": message,
        "priority": priority,
        "tags": [tag],
    }
    if deeplink:
        payload["click"] = deeplink
        payload["actions"] = [
            {"action": "view", "label": "Open in cmux Remote", "url": deeplink, "clear": True}
        ]

    headers = {"Content-Type": "application/json"}
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"

    try:
        req = urllib.request.Request(
            NTFY_SERVER.rstrip("/") + "/",
            data=json.dumps(payload).encode(),
            headers=headers,
        )
        urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S).read()
    except Exception as exc:  # best-effort: never break the notification
        print(f"cmux-notify-ntfy: push failed: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
