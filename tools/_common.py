import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CARDS = os.path.join(ROOT, "cards", "sample.json")


def cards_path():
    return sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CARDS


def load_cards():
    return json.load(open(cards_path(), encoding="utf-8"))


def card_kws(card):
    return {k.get("id") for k in card.get("keywords", [])}


def nonhero(cards):
    return [c for c in cards if c.get("type") != "hero"]
