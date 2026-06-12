#!/usr/bin/env python3
"""Local production-mirror for testing the web client.

Serves the exported Godot web client AND proxies /ws to the local prism_server,
both on one port -- exactly what caddy does in production. So you open the URL and
the client auto-connects to /ws (same origin) with no manual server address.

Run prism_server first:  ./build/server/prism_server 8080 cards/sample.json
Then:                    python3 deploy/local_serve.py
Open:                    http://127.0.0.1:8231/
"""
import asyncio
import pathlib
import sys

import aiohttp
from aiohttp import web

WEBDIR = (pathlib.Path(__file__).resolve().parent.parent
          / "client-godot" / ".web-export")
BACKEND = "ws://127.0.0.1:8080"   # the prism_server WebSocket
PORT = 8231

MIME = {".wasm": "application/wasm", ".js": "text/javascript",
        ".pck": "application/octet-stream", ".html": "text/html",
        ".png": "image/png", ".json": "application/json"}


async def ws_proxy(request: web.Request) -> web.WebSocketResponse:
    browser = web.WebSocketResponse(max_msg_size=0)
    await browser.prepare(request)
    session = aiohttp.ClientSession()
    try:
        server = await session.ws_connect(BACKEND, max_msg_size=0)
    except Exception as e:
        print("proxy: cannot reach", BACKEND, "->", e)
        await browser.close()
        await session.close()
        return browser

    async def pump(src, dst):
        async for msg in src:
            if msg.type == aiohttp.WSMsgType.TEXT:
                await dst.send_str(msg.data)
            elif msg.type == aiohttp.WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            else:
                break

    await asyncio.gather(pump(browser, server), pump(server, browser),
                         return_exceptions=True)
    await server.close()
    await session.close()
    return browser


async def static(request: web.Request) -> web.StreamResponse:
    rel = request.match_info["tail"] or "index.html"
    fp = (WEBDIR / rel).resolve()
    if WEBDIR.resolve() not in fp.parents and fp != WEBDIR.resolve():
        return web.Response(status=403)
    if not fp.is_file():
        return web.Response(status=404, text="not found: " + rel)
    return web.FileResponse(fp, headers={"Content-Type": MIME.get(fp.suffix, "")}
                            if fp.suffix in MIME else None)


def main() -> None:
    if not (WEBDIR / "index.html").is_file():
        sys.exit("No export at %s -- run the Web export first (see deploy/README.md)."
                 % WEBDIR)
    app = web.Application()
    app.router.add_get("/ws", ws_proxy)
    app.router.add_get("/{tail:.*}", static)
    print("Serving %s\n  client: http://127.0.0.1:%d/\n  /ws  -> %s"
          % (WEBDIR, PORT, BACKEND))
    web.run_app(app, host="127.0.0.1", port=PORT, print=None)


if __name__ == "__main__":
    main()
