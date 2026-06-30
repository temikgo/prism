#!/usr/bin/env python3
"""Autonomous per-card balance screen for Prism.

Reads the per-game records that `prism_selfplay --draft` emits (one JSON line per
game: both 40-card decklists, heroes, winner) and fits a differenced linear
probability model: outcome y=1 if seat0 won, regressed on, per card, the signed
copy difference x_card = (copies in seat0 deck) - (copies in seat1 deck), plus a
first-player intercept and differenced hero dummies. The card coefficient beta is
the marginal win contribution of one extra copy versus the opponent, in
percentage points -- the single "how strong is this card" number. Honest SEs come
from a bootstrap over games; outliers are gated with a Benjamini-Hochberg FDR.

Why differenced and one-row-per-game: each game contributes a single independent
row, the symmetric first-player edge and any global level cancel, and there is no
within-game correlation to cluster on. This is the contrast the full-pool GIH
metric could not provide (there every game held every card -> zero variation).

Reuses tools/balance.py (cost/power) only to show its static R next to the
empirical beta -- never as a steering signal.

Subcommands:
  screen  <games.jsonl>            analyse an existing run -> JSON + markdown
  run     <N>                      run prism_selfplay --draft N games, then screen

Run standalone (no Claude Code): python3 tools/balance_lab.py run 2000
"""

import argparse
import importlib.util
import json
import math
import os
import subprocess
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARDS = os.path.join(ROOT, "cards", "sample.json")
def _selfplay_bin():
    # Prefer the Release build (build-release/) -- self-play in Debug is ~8x
    # slower, which makes the screen unusably slow. Fall back to build/.
    rel = os.path.join(ROOT, "build-release", "engine", "prism_selfplay")
    dbg = os.path.join(ROOT, "build", "engine", "prism_selfplay")
    return rel if os.path.exists(rel) else dbg


SELFPLAY = _selfplay_bin()


def load_balance_model():
    """Import tools/balance.py as a library for its cost()/power() (R column)."""
    path = os.path.join(ROOT, "tools", "balance.py")
    spec = importlib.util.spec_from_file_location("prism_balance", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def card_table(cards_path):
    """id -> card dict, plus a mana_value helper, from the card set."""
    raw = json.load(open(cards_path, encoding="utf-8"))
    cards = {c["id"]: c for c in raw if c.get("type") != "hero"}
    return cards


def mana_value(card):
    c = card.get("cost", {})
    return c.get("generic", 0) + sum(v for k, v in c.items() if k != "generic")


def load_games(jsonl_path):
    games = []
    with open(jsonl_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            g = json.loads(line)
            if g.get("winner", -1) in (0, 1):
                games.append(g)
    return games


def build_design(games, card_ids, hero_ids):
    """Differenced design: one row per game.

    Columns: [intercept] + one per card (copy diff seat0-seat1) + one per hero
    except a reference (differenced presence). y = 1 if seat0 (the winner field's
    0) won. Returns X, y, and the column-name list.
    """
    ncard = len(card_ids)
    cidx = {c: i for i, c in enumerate(card_ids)}
    ref_hero = hero_ids[0] if hero_ids else None
    heroes = [h for h in hero_ids if h != ref_hero]
    hidx = {h: i for i, h in enumerate(heroes)}
    ncol = 1 + ncard + len(heroes)

    X = np.zeros((len(games), ncol))
    y = np.zeros(len(games))
    for r, g in enumerate(games):
        X[r, 0] = 1.0  # intercept = first-player baseline
        d0, d1 = g["deck0"], g["deck1"]
        for c, n in d0.items():
            if c in cidx:
                X[r, 1 + cidx[c]] += n
        for c, n in d1.items():
            if c in cidx:
                X[r, 1 + cidx[c]] -= n
        if g["hero0"] in hidx:
            X[r, 1 + ncard + hidx[g["hero0"]]] += 1.0
        if g["hero1"] in hidx:
            X[r, 1 + ncard + hidx[g["hero1"]]] -= 1.0
        y[r] = 1.0 if g["winner"] == 0 else 0.0
    names = ["intercept"] + list(card_ids) + ["hero:" + h for h in heroes]
    return X, y, names


def fit_ridge(X, y, alpha, penalize):
    """Ridge normal equations; `penalize` is a 0/1 mask (intercept unpenalised)."""
    A = X.T @ X + alpha * np.diag(penalize)
    return np.linalg.solve(A, X.T @ y)


def bootstrap_se(X, y, alpha, penalize, n_boot, seed):
    rng = np.random.default_rng(seed)
    n = X.shape[0]
    out = np.empty((n_boot, X.shape[1]))
    for b in range(n_boot):
        idx = rng.integers(0, n, n)
        out[b] = fit_ridge(X[idx], y[idx], alpha, penalize)
    return out.std(axis=0, ddof=1)


def two_sided_p(z):
    z = np.asarray(z, float)
    return 2.0 * (1.0 - 0.5 * (1.0 + np.vectorize(math.erf)(np.abs(z) / math.sqrt(2))))


def cost_residual(card_beta, card_se, card_ids, cards):
    """Residual of beta against what a VANILLA body of the same cost AND stats
    would score. Trend basis: cubic in mana value (1, mv, mv^2, mv^3) PLUS board
    stat-sum (atk+hp; 0 for spells/auras), weighted by 1/se^2.

    Beta over greedy self-play has TWO confounds, each needing its own control:
      1. NON-LINEAR COST -- the cheapest cards tower (smooth curve / always a
         play). The cubic-in-mv term absorbs this (a 0-mana 1/1 stops reading
         +5.8pp). A linear trend could not bend to that cheap spike.
      2. BODY vs SPELL TEMPO -- at equal cost a body beats a spell regardless of
         power (board presence wins greedy games). Proof: a 2/1@1 vanilla and a
         2/1@1 + keyword score the same beta -- the keyword adds ~0. The stat-sum
         term absorbs this: each card is compared to a vanilla of its OWN stats,
         so a 2/1 vanilla lands ~0 and a 2/1 + keyword shows only the keyword's
         measured value.
    So this residual = self-play value ABOVE a same-cost, same-stat vanilla --
    the worth of the card's keywords/effects. Vanilla bodies read ~0 by
    construction (they ARE the baseline); a 2/1@1 is weak filler, not a star.

    Division of labour with Tier-1 (`balance.py` R = power - cost): subtracting
    stats here would hide a card broken purely by OVER-STATTING (6/6@3), but
    Tier-1's power model owns that axis (it counts stats). So Tier-2 (this
    residual) catches mis-valued KEYWORDS/EFFECTS; Tier-1 catches mis-statted/
    mis-costed bodies. A real outlier is flagged by the RIGHT tier.
    """
    mv = np.array([mana_value(cards[c]) for c in card_ids], float)

    def statsum(c):
        s = cards[c].get("stats") or {}
        return float(s.get("atk", 0) + s.get("hp", 0))

    ss = np.array([statsum(c) for c in card_ids])
    T = np.column_stack([np.ones(len(card_ids)), mv, mv ** 2, mv ** 3, ss])
    w = 1.0 / np.maximum(card_se ** 2, 1e-9)
    WT = T * w[:, None]
    coef = np.linalg.solve(T.T @ WT, WT.T @ card_beta)
    trend = T @ coef
    resid = card_beta - trend
    resid_z = np.where(card_se > 0, resid / card_se, 0.0)
    return resid, resid_z


def bh_flag(pvals, q=0.1):
    """Benjamini-Hochberg: boolean array, True = reject null at FDR q."""
    p = np.asarray(pvals)
    m = len(p)
    order = np.argsort(p)
    thresh = q * (np.arange(1, m + 1)) / m
    passed = p[order] <= thresh
    flag = np.zeros(m, dtype=bool)
    if passed.any():
        kmax = np.where(passed)[0].max()
        flag[order[: kmax + 1]] = True
    return flag


def univariate_wr(games, card_ids):
    """WR when seat has >=1 copy and opp has 0, vs the reverse -- a model-free
    sanity readout of each card's contrast."""
    win_in = {c: 0 for c in card_ids}
    n_in = {c: 0 for c in card_ids}
    win_out = {c: 0 for c in card_ids}
    n_out = {c: 0 for c in card_ids}
    for g in games:
        s0win = g["winner"] == 0
        d0, d1 = g["deck0"], g["deck1"]
        for c in card_ids:
            a, b = d0.get(c, 0), d1.get(c, 0)
            if a > b:
                n_in[c] += 1
                win_in[c] += 1 if s0win else 0
                n_out[c] += 1
                win_out[c] += 0 if s0win else 1
            elif b > a:
                n_in[c] += 1
                win_in[c] += 0 if s0win else 1
                n_out[c] += 1
                win_out[c] += 1 if s0win else 0
    res = {}
    for c in card_ids:
        wi = 100.0 * win_in[c] / n_in[c] if n_in[c] else float("nan")
        wo = 100.0 * win_out[c] / n_out[c] if n_out[c] else float("nan")
        res[c] = (wi, wo, n_in[c])
    return res


def screen(jsonl_path, cards_path, alpha, n_boot, seed, out_prefix):
    games = load_games(jsonl_path)
    if len(games) < 50:
        print(f"only {len(games)} decided games -- too few to screen",
              file=sys.stderr)
        return None
    cards = card_table(cards_path)
    card_ids = sorted(cards.keys())
    hero_ids = sorted(
        {g["hero0"] for g in games} | {g["hero1"] for g in games})

    X, y, names = build_design(games, card_ids, hero_ids)
    penalize = np.ones(X.shape[1])
    penalize[0] = 0.0  # never penalise the intercept

    beta = fit_ridge(X, y, alpha, penalize)
    se = bootstrap_se(X, y, alpha, penalize, n_boot, seed)
    z = np.where(se > 0, beta / se, 0.0)

    ncard = len(card_ids)
    card_beta = beta[1 : 1 + ncard] * 100.0  # pp
    card_se = se[1 : 1 + ncard] * 100.0
    card_z = z[1 : 1 + ncard]

    # Cost/type-adjusted residual: the bot-robust per-card deviation. This is the
    # primary outlier signal (raw beta flags whole cheap/spell classes the bot
    # mistreats; the residual flags cards that deviate from their own peers).
    resid, resid_z = cost_residual(card_beta, card_se, card_ids, cards)
    card_flag = bh_flag(two_sided_p(resid_z), q=0.1)
    card_p = two_sided_p(card_z)

    # presence count per card (games where it appeared in either deck)
    present = {c: 0 for c in card_ids}
    for g in games:
        for c in set(g["deck0"]) | set(g["deck1"]):
            if c in present:
                present[c] += 1

    bal = load_balance_model()
    uni = univariate_wr(games, card_ids)

    rows = []
    for i, cid in enumerate(card_ids):
        cd = cards[cid]
        p, _ = bal.power(cd)
        c_cost, _, _ = bal.cost(cd)
        R = float(p - c_cost)
        wi, wo, n_contrast = uni[cid]
        # Confirmed = both tiers agree: Tier-2 (resid FDR) flags it AND Tier-1
        # (balance.py R) is off in the SAME direction by >=0.75 mana. This drops
        # the vanilla/cheap-body false positives (Tier-2 over-rates cheap tempo;
        # Tier-1 correctly rates a 2/1@1 as fair, R~=0) while keeping cards both
        # the formula and self-play call broken. Tier-2-only flags stay advisory.
        confirmed = bool(card_flag[i] and abs(R) >= 0.75 and
                         (resid[i] > 0) == (R > 0))
        rows.append({
            "id": cid,
            "beta_pp": round(float(card_beta[i]), 2),
            "se_pp": round(float(card_se[i]), 2),
            "z": round(float(card_z[i]), 2),
            "resid_pp": round(float(resid[i]), 2),
            "resid_z": round(float(resid_z[i]), 2),
            "p": float(card_p[i]),
            "fdr_outlier": bool(card_flag[i]),
            "confirmed": confirmed,
            "n_present": present[cid],
            "mana_value": mana_value(cd),
            "type": cd.get("type"),
            "R": round(R, 2),
            "wr_in": round(wi, 1) if wi == wi else None,
            "wr_out": round(wo, 1) if wo == wo else None,
        })
    rows.sort(key=lambda r: r["resid_pp"], reverse=True)

    intercept_pp = round(float(beta[0] * 100.0), 2)
    meta = {
        "jsonl": os.path.relpath(jsonl_path, ROOT),
        "cards": os.path.relpath(cards_path, ROOT),
        "n_games": len(games),
        "alpha": alpha,
        "n_boot": n_boot,
        "seat0_baseline_winrate_pp": intercept_pp,
        "n_outliers": int(sum(card_flag)),
    }
    report = {"meta": meta, "cards": rows}

    json_path = out_prefix + ".json"
    json.dump(report, open(json_path, "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    md_path = out_prefix + ".md"
    write_markdown(md_path, report)
    print_summary(report)
    print(f"\nwritten: {json_path}  +  {md_path}")
    return report


def write_markdown(path, report):
    m = report["meta"]
    rows = report["cards"]
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# Balance screen\n\n")
        f.write(f"- games: {m['n_games']}  alpha: {m['alpha']}  "
                f"boot: {m['n_boot']}\n")
        f.write(f"- seat0 baseline winrate (first-player edge): "
                f"{m['seat0_baseline_winrate_pp']}%\n")
        f.write(f"- FDR outliers (q=0.1): {m['n_outliers']}\n\n")
        f.write("beta = marginal win contribution per extra copy vs opponent "
                "(pp). resid = beta minus the cost/type trend (bot-robust "
                "per-card deviation); FDR flags by resid. z = beta/bootstrap-SE."
                "\n\n")
        f.write("| card | resid(pp) | beta(pp) | z | FDR | mv | type | R | n |\n")
        f.write("|---|---:|---:|---:|:-:|---:|:--|---:|---:|\n")
        for r in rows:
            flag = "**!**" if r["fdr_outlier"] else ""
            f.write(f"| {r['id']} | {r['resid_pp']:+.2f} | {r['beta_pp']:+.2f} | "
                    f"{r['z']:+.2f} | {flag} | {r['mana_value']} | {r['type']} | "
                    f"{r['R']:+.2f} | {r['n_present']} |\n")


def print_summary(report):
    m = report["meta"]
    rows = report["cards"]
    print(f"\nscreen: {m['n_games']} games, alpha={m['alpha']}, "
          f"first-player baseline {m['seat0_baseline_winrate_pp']}%")
    outliers = [r for r in rows if r["fdr_outlier"]]
    print(f"cost-adjusted FDR outliers (q=0.1): {len(outliers)}")
    for r in sorted(outliers, key=lambda r: -r["resid_pp"]):
        print(f"  {r['id']:<30} resid={r['resid_pp']:+5.2f}pp  "
              f"beta={r['beta_pp']:+5.2f}pp  z_resid={r['resid_z']:+5.2f}  "
              f"mv={r['mana_value']}  {r['type']}")
    print("\ntop 5 over / under by cost-adjusted residual:")
    for r in rows[:5]:
        print(f"  + {r['id']:<30} resid={r['resid_pp']:+5.2f}pp  "
              f"beta={r['beta_pp']:+5.2f}pp")
    for r in rows[-5:]:
        print(f"  - {r['id']:<30} resid={r['resid_pp']:+5.2f}pp  "
              f"beta={r['beta_pp']:+5.2f}pp")


def crn_paired(jsonl_a, jsonl_b, card_id):
    """Common-random-numbers paired effect of one card between two runs that
    share the seed set. The two runs differ only in the card's definition, so
    the per-game outcome difference d = y_a - y_b is caused solely by the card;
    regressing d on the card's signed copy-diff x = (seat0 - seat1) recovers its
    win contribution with the variance collapsed (everything else is identical).
    Far more powerful than comparing two independent screens. Returns
    (beta_pp, se_pp, z, n_flipped, decks_match)."""
    A = {json.loads(l)["seed"]: json.loads(l)
         for l in open(jsonl_a, encoding="utf-8") if l.strip()}
    B = {json.loads(l)["seed"]: json.loads(l)
         for l in open(jsonl_b, encoding="utf-8") if l.strip()}
    seeds = sorted(set(A) & set(B))
    d = np.zeros(len(seeds))
    x = np.zeros(len(seeds))
    decks_match = 0
    for i, s in enumerate(seeds):
        ga, gb = A[s], B[s]
        if ga["deck0"] == gb["deck0"] and ga["deck1"] == gb["deck1"]:
            decks_match += 1
        ya = 1.0 if ga["winner"] == 0 else 0.0
        yb = 1.0 if gb["winner"] == 0 else 0.0
        d[i] = ya - yb
        x[i] = ga["deck0"].get(card_id, 0) - ga["deck1"].get(card_id, 0)
    sx2 = float((x * x).sum())
    if sx2 == 0:
        return 0.0, 0.0, 0.0, int((d != 0).sum()), decks_match
    beta = float((d * x).sum() / sx2)
    resid = d - beta * x
    sigma2 = float((resid ** 2).sum() / (len(seeds) - 1))
    se = math.sqrt(sigma2 / sx2)
    z = beta / se if se > 0 else 0.0
    return beta * 100.0, se * 100.0, z, int((d != 0).sum()), decks_match


def run_selfplay(n_games, cards_path, threads, jsonl_path):
    if not os.path.exists(SELFPLAY):
        sys.exit(f"binary not found: {SELFPLAY} (build Release first)")
    cmd = [SELFPLAY, str(n_games), cards_path, str(threads), "--draft",
           "--jsonl", jsonl_path, "--report", "/dev/null"]
    print("running:", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser(description="Prism per-card balance screen")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("screen", help="analyse an existing per-game jsonl")
    s.add_argument("jsonl")
    s.add_argument("--cards", default=CARDS)
    s.add_argument("--alpha", type=float, default=5.0)
    s.add_argument("--boot", type=int, default=300)
    s.add_argument("--seed", type=int, default=12345)
    s.add_argument("--out", default=os.path.join(ROOT, "balance-screen"))

    r = sub.add_parser("run", help="run selfplay --draft then screen")
    r.add_argument("games", type=int)
    r.add_argument("--cards", default=CARDS)
    r.add_argument("--threads", type=int, default=os.cpu_count() or 4)
    r.add_argument("--alpha", type=float, default=5.0)
    r.add_argument("--boot", type=int, default=300)
    r.add_argument("--seed", type=int, default=12345)
    r.add_argument("--jsonl", default=os.path.join(ROOT, "selfplay-games.jsonl"))
    r.add_argument("--out", default=os.path.join(ROOT, "balance-screen"))

    c = sub.add_parser(
        "crn", help="paired CRN effect of one card between two same-seed runs")
    c.add_argument("jsonl_a")
    c.add_argument("jsonl_b")
    c.add_argument("card")

    a = ap.parse_args()
    if a.cmd == "screen":
        screen(a.jsonl, a.cards, a.alpha, a.boot, a.seed, a.out)
    elif a.cmd == "run":
        run_selfplay(a.games, a.cards, a.threads, a.jsonl)
        screen(a.jsonl, a.cards, a.alpha, a.boot, a.seed, a.out)
    elif a.cmd == "crn":
        beta, se, z, flipped, dm = crn_paired(a.jsonl_a, a.jsonl_b, a.card)
        print(f"CRN paired effect of {a.card}:")
        print(f"  beta = {beta:+.2f} pp/copy   SE = {se:.2f}   z = {z:+.2f}")
        print(f"  outcomes changed: {flipped};  decks identical: {dm}")


if __name__ == "__main__":
    main()
