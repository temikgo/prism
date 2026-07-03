#!/usr/bin/env python3
"""Procedural sound effects for the Prism client -- pure stdlib, no numpy.

Synthesises a small "crystal / light" set of one-shot SFX plus a seamless ambient
pad loop, written as 22050 Hz mono 16-bit WAV into client-godot/sfx/. Nothing here
is sample-based, so it is self-contained and license-free, and every sound is a
handful of parameters -- tune the numbers and re-run. Run from the repo root:

    python3 tools/gen_sfx.py

The crystal timbre is an inharmonic bell (a few partials at bell-like ratios, the
higher ones decaying faster) plus an optional bright noise transient. Light is the
airy high shimmer layered on top. Combat sounds swap the bell for a noisy body.
"""

import math
import os
import random
import struct
import wave

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), "..", "client-godot", "sfx")

BELL_RATIOS = [1.0, 2.76, 5.40, 8.93]  # inharmonic partials of a struck bar/bell


def _env(n, attack, decay, hold=0.0):
    """Percussive envelope over n samples: linear attack, hold, exp decay."""
    out = [0.0] * n
    a = max(1, int(attack * SR))
    h = int(hold * SR)
    for i in range(n):
        if i < a:
            out[i] = i / a
        elif i < a + h:
            out[i] = 1.0
        else:
            out[i] = math.exp(-(i - a - h) / (decay * SR))
    return out


def _bell(freq, dur, decay, bright=1.0):
    """Inharmonic bell: partials at BELL_RATIOS, higher ones shorter + softer."""
    n = int(dur * SR)
    out = [0.0] * n
    for k, ratio in enumerate(BELL_RATIOS):
        amp = bright ** k / (k + 1)
        d = decay / (1.0 + k * 0.8)  # higher partials ring down faster
        w = 2.0 * math.pi * freq * ratio
        for i in range(n):
            out[i] += amp * math.exp(-i / (d * SR)) * math.sin(w * i / SR)
    return out


def _shimmer(freq, dur, voices=4):
    """Airy high shimmer: detuned sines with slow tremolo, quick decay."""
    n = int(dur * SR)
    out = [0.0] * n
    for v in range(voices):
        f = freq * (1.0 + 0.012 * (v - voices / 2.0))
        trem = 5.0 + v
        for i in range(n):
            t = i / SR
            env = math.exp(-t * 6.0) * (0.6 + 0.4 * math.sin(2 * math.pi * trem * t))
            out[i] += (0.5 / voices) * env * math.sin(2 * math.pi * f * t)
    return out


def _noise(dur, decay, lp=0.0, hp=0.0):
    """Filtered noise burst (one-pole LP/HP), exp-decaying -- transients/swishes."""
    n = int(dur * SR)
    raw = [random.uniform(-1.0, 1.0) for _ in range(n)]
    if lp > 0.0:
        a = math.exp(-2.0 * math.pi * lp / SR)
        y = 0.0
        for i in range(n):
            y = (1 - a) * raw[i] + a * y
            raw[i] = y
    if hp > 0.0:
        a = math.exp(-2.0 * math.pi * hp / SR)
        y = 0.0
        prev = 0.0
        for i in range(n):
            y = a * (y + raw[i] - prev)
            prev_in = raw[i]
            raw[i] = y
            prev = prev_in
    env = _env(n, 0.001, decay)
    return [raw[i] * env[i] for i in range(n)]


def _mix(*layers):
    n = max(len(x) for x in layers)
    out = [0.0] * n
    for x in layers:
        for i in range(len(x)):
            out[i] += x[i]
    return out


def _apply(sig, env):
    return [sig[i] * env[i] for i in range(min(len(sig), len(env)))]


def _sweep(f0, f1, dur, decay):
    """A pitch glide (rising sparkle / falling dissolve) with exp decay."""
    n = int(dur * SR)
    out = [0.0] * n
    phase = 0.0
    for i in range(n):
        t = i / n
        f = f0 * (f1 / f0) ** t
        phase += 2.0 * math.pi * f / SR
        out[i] = math.exp(-i / (decay * SR)) * math.sin(phase)
    return out


# --- the sounds --------------------------------------------------------------


def ui_click():
    # Soft, rounded button press -- deliberately NOT a bright/sharp tick. Sharp
    # onsets are reserved for forceful actions (attack/damage/death/aura_break).
    return _apply(_bell(440, 0.10, 0.05, 0.28), _env(int(0.10 * SR), 0.006, 0.05))


def ui_tap():
    # Warm little pluck for selecting a card or tile (mulligan pick, hero/deck) --
    # wooden and gentle, a different voice from the button click.
    body = _apply(_bell(680, 0.11, 0.055, 0.3), _env(int(0.11 * SR), 0.004, 0.055))
    tock = [0.12 * x for x in _noise(0.02, 0.01, lp=1200)]  # soft wooden onset
    return _mix(body, tock)


def ui_toggle():
    # A tiny soft tick for flipping a filter chip or a mana crystal on/off.
    return _apply(_bell(920, 0.06, 0.03, 0.28), _env(int(0.06 * SR), 0.003, 0.03))


def card_play():
    body = _apply(_bell(320, 0.28, 0.12, 0.7), _env(int(0.28 * SR), 0.004, 0.12))
    tap = [0.4 * x for x in _noise(0.05, 0.03, lp=2500)]
    return _mix(body, tap, [0.5 * x for x in _shimmer(1400, 0.22)])


def card_reveal():
    return _mix(_bell(523, 0.5, 0.3, 0.9), [0.7 * x for x in _shimmer(1568, 0.45)],
                _sweep(700, 1600, 0.4, 0.22))


def mana_place():
    # A gentle crystal set-down (happens every turn), not a bright sparkle.
    return _mix(_bell(660, 0.22, 0.14, 0.45), [0.18 * x for x in _shimmer(1500, 0.16)])


def draw():
    # A soft paper riffle -- band-limited so it is not a hissy every-turn sound.
    return _mix([0.7 * x for x in _noise(0.13, 0.05, hp=1100, lp=4000)],
                [0.2 * x for x in _sweep(850, 1700, 0.12, 0.05)])


def attack_hit():
    body = [0.9 * x for x in _noise(0.14, 0.05, lp=1400)]
    crack = [0.6 * x for x in _noise(0.04, 0.02, hp=2500)]
    low = _apply([math.sin(2 * math.pi * 90 * i / SR) for i in range(int(0.14 * SR))],
                 _env(int(0.14 * SR), 0.001, 0.05))
    return _mix(body, crack, low)


def damage():
    thud = [0.8 * x for x in _noise(0.16, 0.06, lp=900)]
    low = _apply([math.sin(2 * math.pi * 70 * i / SR) for i in range(int(0.16 * SR))],
                 _env(int(0.16 * SR), 0.001, 0.06))
    return _mix(thud, low)


def death():
    return _mix(_sweep(420, 90, 0.5, 0.28), [0.5 * x for x in _noise(0.4, 0.2, lp=1200)])


def summon():
    # Rising sparkle: a quick arpeggio of bell partials climbing.
    layers = []
    for k, f in enumerate([523, 659, 784, 1047]):
        start = int(k * 0.05 * SR)
        b = _apply(_bell(f, 0.3, 0.16, 0.9), _env(int(0.3 * SR), 0.002, 0.16))
        layers.append([0.0] * start + b)
    return _mix(*layers, [0.5 * x for x in _shimmer(1800, 0.35)])


def heal():
    # Warm major chord rising softly.
    layers = [_apply(_bell(f, 0.45, 0.3, 0.7), _env(int(0.45 * SR), 0.06, 0.3))
              for f in [392, 494, 587]]
    return _mix(*layers, [0.4 * x for x in _shimmer(1568, 0.4)])


def turn_start():
    # Warm, low swell -- a soft "your move" chime, deliberately NOT bright/ringy.
    return _mix(
        _apply(_bell(294, 0.75, 0.55, 0.5), _env(int(0.75 * SR), 0.04, 0.55)),  # D4
        _apply(_bell(196, 0.75, 0.55, 0.4), _env(int(0.75 * SR), 0.06, 0.55)),  # G3
        [0.22 * x for x in _shimmer(784, 0.3, 3)])  # faint, low shimmer only


def ui_hover():
    # Barely-there soft tick -- fires on every hover, so kept low and un-piercing.
    return _apply(_bell(1150, 0.05, 0.03, 0.32), _env(int(0.05 * SR), 0.003, 0.03))


def aura():
    # An aura settling in: an airy shimmer swelling over a soft, slow body.
    return _mix([0.7 * x for x in _shimmer(784, 0.55, 5)],
                _apply(_bell(392, 0.55, 0.4, 0.6), _env(int(0.55 * SR), 0.1, 0.4)),
                [0.3 * x for x in _sweep(500, 900, 0.45, 0.32)])


def aura_break():
    # An aura shattering: a glassy hiss, a downward slide, cracking partials.
    return _mix([0.8 * x for x in _noise(0.28, 0.12, hp=2000)],
                _sweep(1500, 380, 0.35, 0.2),
                [0.5 * x for x in _bell(920, 0.32, 0.12, 1.1)])


def hero_hit():
    # Heavier than a creature's -- a low punch with grit, for a blow to your face.
    low = _apply([math.sin(2 * math.pi * 55 * i / SR) for i in range(int(0.24 * SR))],
                 _env(int(0.24 * SR), 0.001, 0.1))
    body = [0.9 * x for x in _noise(0.22, 0.09, lp=700)]
    crack = [0.5 * x for x in _noise(0.05, 0.02, hp=1800)]
    return _mix(low, body, crack)


def decision_prompt():
    a = _apply(_bell(784, 0.18, 0.12, 0.8), _env(int(0.18 * SR), 0.003, 0.12))
    b = _apply(_bell(1047, 0.3, 0.16, 0.8), _env(int(0.3 * SR), 0.003, 0.16))
    return _mix(a, [0.0] * int(0.14 * SR) + b)


def victory():
    layers = []
    for k, f in enumerate([523, 659, 784, 1047]):  # ascending major arpeggio
        start = int(k * 0.14 * SR)
        b = _apply(_bell(f, 0.7, 0.4, 0.9), _env(int(0.7 * SR), 0.004, 0.4))
        layers.append([0.0] * start + b)
    return _mix(*layers, [0.4 * x for x in _shimmer(2093, 0.8)])


def defeat():
    layers = []
    for k, f in enumerate([440, 392, 330, 262]):  # descending, minor mood
        start = int(k * 0.18 * SR)
        b = _apply(_bell(f, 0.8, 0.5, 0.6), _env(int(0.8 * SR), 0.01, 0.5))
        layers.append([0.0] * start + b)
    return _mix(*layers)


# A minor, one bar per chord: i - VI - III - VII - i - VI - iv - V, so it wanders
# and resolves without ever landing on a bright cadence. (triad freqs, bass root)
_PROG = [
    ([220.00, 261.63, 329.63], 110.00),  # Am
    ([174.61, 220.00, 261.63], 87.31),   # F
    ([261.63, 329.63, 392.00], 130.81),  # C
    ([196.00, 246.94, 293.66], 98.00),   # G
    ([220.00, 261.63, 329.63], 110.00),  # Am
    ([174.61, 220.00, 261.63], 87.31),   # F
    ([293.66, 349.23, 440.00], 146.83),  # Dm
    ([164.81, 207.65, 246.94], 82.41),   # E (dark, low voicing)
]
# A-minor pentatonic across two octaves -- the melody only ever picks from these,
# so every note sits in the harmony no matter which chord is under it.
_PENT = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25, 587.33, 659.25]


def _add_voice(out, start, freq, dur_s, amp, attack, release, detune):
    n = int(dur_s * SR)
    voices = (1.0, 1.004, 0.996) if detune else (1.0,)
    for i in range(n):
        idx = start + i
        if idx >= len(out):
            break
        t = i / SR
        rem = dur_s - t
        if t < attack:
            e = t / attack
        elif rem < release:
            e = rem / release
        else:
            e = 1.0
        s = 0.0
        for v in voices:
            s += math.sin(2.0 * math.pi * freq * v * i / SR)
        out[idx] += amp * e * s / len(voices)


def _add_bell(out, start, freq, amp, dur_s):
    b = _bell(freq, dur_s, dur_s * 0.5, 0.45)  # mellow, not a bright ping
    e = _env(len(b), 0.02, dur_s * 0.5)
    for i in range(len(b)):
        if start + i < len(out):
            out[start + i] += amp * b[i] * e[i]


def _reverb(sig):
    """Cheap multi-tap ambience so the pads sit in a soft space, not bone-dry."""
    out = list(sig)
    for dt, g in [(0.09, 0.26), (0.17, 0.19), (0.31, 0.13), (0.43, 0.08)]:
        d = int(dt * SR)
        for i in range(d, len(sig)):
            out[i] += g * sig[i - d]
    return out


def _loopify(sig, dur, xf):
    """Make `dur` seconds seamless: crossfade the tail (rendered past dur) back over
    the head, so playing the end into the start is continuous."""
    n = int(dur * SR)
    f = int(xf * SR)
    loop = sig[:n]
    for i in range(f):
        w = i / f
        loop[i] = sig[i] * w + sig[n + i] * (1.0 - w)
    return loop


def ambient(dur=64.0, xf=2.5):
    """A slow, evolving A-minor piece rather than a static drone: legato chord pads
    over a soft bass, a sparse pentatonic bell melody whose phrasing keeps shifting
    (seeded, so the bytes stay stable), a little reverb, looped seamlessly. 16 bars
    at ~60 BPM so the return is far enough apart not to nag."""
    bar = 4.0
    total = dur + xf
    n = int(total * SR)
    out = [0.0] * n
    nbars = int(total / bar) + 1
    for b in range(nbars):
        chord, bass = _PROG[b % len(_PROG)]
        s0 = int(b * bar * SR)
        for j, f in enumerate(chord):  # legato pad, slightly overlapping next bar
            _add_voice(out, s0, f, bar * 1.15, 0.05 / (1 + j * 0.2), 0.6, 1.2, True)
        _add_voice(out, s0, bass, bar * 1.05, 0.10, 0.4, 0.8, False)  # soft bass
    # Melody: a gentle, fairly continuous line that wanders mostly by step (no big
    # leaps or long gaps), sitting quietly UNDER the pads rather than over them.
    r = random.Random(11)  # deterministic phrasing
    i = 3
    t = 2.0
    while t < dur:
        i = max(0, min(len(_PENT) - 1, i + r.choice([-2, -1, -1, 0, 1, 1, 2])))
        if r.random() < 0.12:
            t += 0.5  # a short breath, not a silence
            continue
        _add_bell(out, int(t * SR), _PENT[i], 0.045, r.choice([0.9, 1.2, 1.2]))
        t += r.choice([0.5, 0.75, 0.75, 1.0])
    return _loopify(_reverb(out), dur, xf)


SOUNDS = {
    # Levels are PERCEIVED-loudness (RMS) targets in one tight range, so the whole
    # set sits at a similar volume (see _normalize): the constant hover is lowest,
    # combat impacts a touch highest, everything else clustered in the middle.
    "ui_hover": (ui_hover, 0.05),
    "ui_click": (ui_click, 0.10),
    "ui_tap": (ui_tap, 0.10),
    "ui_toggle": (ui_toggle, 0.09),
    "mana_place": (mana_place, 0.11),
    "draw": (draw, 0.10),
    "card_play": (card_play, 0.13),
    "card_reveal": (card_reveal, 0.13),
    "summon": (summon, 0.13),
    "aura": (aura, 0.12),
    "heal": (heal, 0.12),
    "turn_start": (turn_start, 0.12),
    "decision_prompt": (decision_prompt, 0.13),
    "attack_hit": (attack_hit, 0.15),
    "damage": (damage, 0.15),
    "hero_hit": (hero_hit, 0.16),
    "death": (death, 0.14),
    "aura_break": (aura_break, 0.14),
    "victory": (victory, 0.14),
    "defeat": (defeat, 0.14),
    "ambient": (ambient, 0.11),
}


def _normalize(sig, target):
    # Match PERCEIVED loudness, not peak: scale so the RMS of the sound's active
    # part (samples above 5% of peak) hits `target`, then keep the peak under a
    # ceiling so transients never clip. A click and a sustained chord with equal
    # peaks are NOT equally loud; this keeps the whole set in one volume range.
    peak = max((abs(x) for x in sig), default=0.0)
    if peak <= 0.0:
        return sig
    thr = peak * 0.05
    active = [x * x for x in sig if abs(x) > thr]
    rms = (sum(active) / len(active)) ** 0.5 if active else peak
    g = target / (rms or 1.0)
    if peak * g > 0.95:  # clip guard -- a sharp transient can't blow past full scale
        g = 0.95 / peak
    return [x * g for x in sig]


def _fade_edges(sig, ms=4.0):
    """Short fade in/out on one-shots so playback never clicks at the boundary."""
    f = int(ms / 1000.0 * SR)
    for i in range(min(f, len(sig))):
        sig[i] *= i / f
        sig[-1 - i] *= i / f
    return sig


def _write(path, sig):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for x in sig:
            v = max(-1.0, min(1.0, x))
            frames += struct.pack("<h", int(v * 32767))
        w.writeframes(bytes(frames))


def main():
    random.seed(7)  # deterministic output -> stable bytes in git
    os.makedirs(OUT, exist_ok=True)
    for name, (fn, level) in SOUNDS.items():
        sig = fn()
        sig = _normalize(sig, level)
        if name != "ambient":
            sig = _fade_edges(sig)
        path = os.path.join(OUT, name + ".wav")
        _write(path, sig)
        print("wrote %s (%.2fs)" % (os.path.relpath(path), len(sig) / SR))


if __name__ == "__main__":
    main()
