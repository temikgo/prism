import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Structural set linters (root C: the lock that keeps the rebuilt set honest
# without manual hints). grammar_lint + check_ids are clean on the live set and
# gate CI; the three structural linters currently DOCUMENT the known audit holes
# (DESIGN.md 8.5) and become gates once Phase A clears them.
LINTERS = [
    ("check_ids", True),
    ("grammar_lint", True),
    ("domination_lint", False),
    ("type_keyword_lint", False),
    ("illusion_keyword_lint", False),
]


def main():
    cards = sys.argv[1] if len(sys.argv) > 1 else None
    failed_gates = 0
    print("== Prism set linters ==\n")
    for name, gating in LINTERS:
        cmd = [sys.executable, os.path.join(ROOT, "tools", name + ".py")]
        if cards:
            cmd.append(cards)
        r = subprocess.run(cmd, capture_output=True, text=True)
        ok = r.returncode == 0
        tag = "PASS" if ok else ("FAIL" if gating else "HOLE")
        kind = "gate" if gating else "advisory"
        print("[%s] %-22s (%s)" % (tag, name, kind))
        body = (r.stdout + r.stderr).strip()
        for line in body.splitlines():
            print("       " + line)
        print()
        if gating and not ok:
            failed_gates += 1

    if failed_gates:
        print("RESULT: %d gating linter(s) failed." % failed_gates)
        sys.exit(1)
    print("RESULT: gates green (structural HOLEs are the known audit backlog).")


if __name__ == "__main__":
    main()
