import asyncio
import json
import subprocess

import websockets

PORT = 8137
SRV = "build/server/prism_server"
CARDS = "cards/sample.json"


async def main():
    proc = subprocess.Popen(
        [SRV, str(PORT), CARDS],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    await asyncio.sleep(0.6)
    uri = f"ws://127.0.0.1:{PORT}"
    c0 = await websockets.connect(uri)
    c1 = await websockets.connect(uri)

    v0 = json.loads(await c0.recv())
    v1 = json.loads(await c1.recv())
    assert v0["you"] == 0 and v1["you"] == 1, (v0["you"], v1["you"])
    assert v0["current"] == 0
    assert "hand" in v0["players"][0], "own hand should be visible"
    assert "hand" not in v0["players"][1], "enemy hand must be hidden"
    # The game opens in the mulligan phase: p0 holds 4, p1 holds 5, no turn yet.
    assert v0["mulligan"] is True, v0
    assert len(v0["players"][0]["hand"]) == 4, v0["players"][0]["hand"]
    assert v0["players"][1]["handCount"] == 5

    # Both players keep their hands; the first turn begins once both are done.
    await c0.send(json.dumps({"action": "mulligan", "indices": []}))
    await c0.recv()
    await c1.recv()
    await c1.send(json.dumps({"action": "mulligan", "indices": []}))
    v0m = json.loads(await c0.recv())
    await c1.recv()
    assert v0m["mulligan"] is False, v0m
    # p0 drew its turn-1 card, so the hand is now 5.
    assert len(v0m["players"][0]["hand"]) == 5, v0m["players"][0]["hand"]

    await c0.send(json.dumps({"action": "endTurn"}))
    v0b = json.loads(await c0.recv())
    v1b = json.loads(await c1.recv())
    assert v0b["current"] == 1 and v1b["current"] == 1

    await c1.send(json.dumps({"action": "endTurn"}))
    v1c = json.loads(await c1.recv())
    await c0.recv()
    assert v1c["current"] == 0

    await c0.close()
    await c1.close()
    try:
        proc.wait(timeout=2)
    except Exception:
        proc.kill()
    print("WS smoke test PASSED")


asyncio.run(main())
