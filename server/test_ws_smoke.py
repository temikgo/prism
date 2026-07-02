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

        # Single-player: a bot room starts at once (no waiting), and after the
        # human ends the turn the server runs the bot's whole turn before the
        # next view -- so play returns with the turn advanced past the bot. The
        # bot's own moves each emit a view, so drain to the awaited condition.
        async def view_until(ws, pred):
            while True:
                m = await recv_view(ws)
                if pred(m):
                    return m

        cb = await websockets.connect(uri)
        await cb.send(json.dumps({"action": "createBotRoom", "hero": "hero_prism"}))
        ms = await expect_type(cb, "matchStart")
        token = ms.get("token")
        assert token, "matchStart must carry a reconnect token"
        vb = await view_until(cb, lambda v: v["mulligan"] is True)
        assert vb["you"] == 0, vb
        await cb.send(json.dumps({"action": "mulligan", "indices": []}))
        vb = await view_until(cb, lambda v: v["mulligan"] is False)
        assert vb["current"] == 0, vb
        turn0 = vb["turn"]
        await cb.send(json.dumps({"action": "endTurn"}))
        vb = await view_until(cb, lambda v: v["current"] == 0 and v["turn"] > turn0)
        assert vb["turn"] >= turn0 + 2, vb  # the bot took its whole turn
        resume_turn = vb["turn"]
        board_after = len(vb["players"][0]["board"])

        # Reconnect: kill the socket, then rejoin the SAME game with the token.
        await cb.close()
        await asyncio.sleep(0.3)  # let the server detach the seat
        cr = await websockets.connect(uri)
        await cr.send(json.dumps({"action": "resume", "token": token}))
        await expect_type(cr, "matchStart")
        vr = await recv_view(cr)
        assert vr["you"] == 0 and vr["mulligan"] is False, vr
        assert vr["turn"] == resume_turn, (vr["turn"], resume_turn)  # same game
        assert len(vr["players"][0]["board"]) == board_after, vr
        # the resumed session keeps playing normally
        await cr.send(json.dumps({"action": "endTurn"}))
        vr2 = await view_until(cr, lambda v: v["current"] == 0 and v["turn"] > resume_turn)
        assert vr2["turn"] > resume_turn, vr2

        # While the seat is held, canResume is false and a resume is rejected --
        # no hijack of a live player (guards the shared-storage token mix-up).
        cr2 = await websockets.connect(uri)
        await cr2.send(json.dumps({"action": "canResume", "token": token}))
        assert not (await expect_type(cr2, "canResume"))["ok"], "seat occupied"
        await cr2.send(json.dumps({"action": "resume", "token": token}))
        assert (await expect_type(cr2, "resumeError"))["reason"] == "seat_active"
        await cr2.close()

        # After the holder drops, canResume flips to true (seat reclaimable).
        await cr.close()
        await asyncio.sleep(0.3)
        cq = await websockets.connect(uri)
        await cq.send(json.dumps({"action": "canResume", "token": token}))
        assert (await expect_type(cq, "canResume"))["ok"], "seat now free"
        await cq.close()

        # A bad/expired token: canResume false, resume rejected.
        cx = await websockets.connect(uri)
        await cx.send(json.dumps({"action": "canResume", "token": "NOSUCHTOKEN0000"}))
        assert not (await expect_type(cx, "canResume"))["ok"]
        await cx.send(json.dumps({"action": "resume", "token": "NOSUCHTOKEN0000"}))
        assert (await expect_type(cx, "resumeError"))["reason"] == "no_session"
        await cx.close()
        print("WS smoke test PASSED (incl. reconnect + canResume)")
    finally:
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.kill()


asyncio.run(asyncio.wait_for(run(), timeout=30))
