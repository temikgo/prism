import asyncio
import json
import subprocess

import websockets

PORT = 8137
SRV = "build/server/prism_server"
CARDS = "cards/sample.json"


async def recv_msg(ws):
    return json.loads(await ws.recv())


async def expect_type(ws, want):
    m = await recv_msg(ws)
    assert m.get("type") == want, m
    return m


async def recv_view(ws):
    while True:
        m = await recv_msg(ws)
        if "type" not in m:
            return m


async def run():
    proc = subprocess.Popen(
        [SRV, str(PORT), CARDS],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    try:
        await asyncio.sleep(0.6)
        uri = f"ws://127.0.0.1:{PORT}"
        c0 = await websockets.connect(uri)
        c1 = await websockets.connect(uri)

        await c0.send(json.dumps({"action": "createRoom", "password": "pw", "hero": "hero_prism"}))
        rc = await expect_type(c0, "roomCreated")
        code = rc["code"]

        await c1.send(json.dumps({"action": "joinRoom", "code": code, "password": "pw", "hero": "hero_eclipse"}))

        await expect_type(c0, "matchStart")
        await expect_type(c1, "matchStart")
        v0 = await recv_view(c0)
        v1 = await recv_view(c1)

        assert v0["you"] == 0 and v1["you"] == 1, (v0["you"], v1["you"])
        assert v0["current"] == 0
        assert "hand" in v0["players"][0], "own hand should be visible"
        assert "hand" not in v0["players"][1], "enemy hand must be hidden"
        assert v0["mulligan"] is True, v0
        assert len(v0["players"][0]["hand"]) == 4, v0["players"][0]["hand"]
        assert v0["players"][1]["handCount"] == 5

        await c0.send(json.dumps({"action": "mulligan", "indices": []}))
        await recv_view(c0)
        await recv_view(c1)
        await c1.send(json.dumps({"action": "mulligan", "indices": []}))
        v0m = await recv_view(c0)
        await recv_view(c1)
        assert v0m["mulligan"] is False, v0m
        assert len(v0m["players"][0]["hand"]) == 5, v0m["players"][0]["hand"]

        await c0.send(json.dumps({"action": "endTurn"}))
        v0b = await recv_view(c0)
        v1b = await recv_view(c1)
        assert v0b["current"] == 1 and v1b["current"] == 1

        await c1.send(json.dumps({"action": "endTurn"}))
        v1c = await recv_view(c1)
        await recv_view(c0)
        assert v1c["current"] == 0

        await c0.close()
        await c1.close()
        print("WS smoke test PASSED")
    finally:
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.kill()


asyncio.run(asyncio.wait_for(run(), timeout=30))
