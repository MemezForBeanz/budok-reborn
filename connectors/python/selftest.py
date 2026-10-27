#!/usr/bin/env python3
"""Self-test against a running game: starts a short match, this script plays both sides through MCP
(random legal moves, a few simulations) until someone wins, and reports what worked.

    python selftest.py --token TOKEN                 # Ninja vs Cowboy
    python selftest.py --token TOKEN --p2 Tester     # with the budok test character installed

The token is in the budok tab of the game's Mod List (or the F8 overlay). It leaves controllers
set to mcp for the test match only; matches you start from the menu use your saved settings.
"""

from __future__ import annotations

import argparse
import os
import random
import sys
import time

from budok_connector import DEFAULT_URL, BudokClient, McpError


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("BUDOK_URL", DEFAULT_URL))
    parser.add_argument("--token", default=os.environ.get("BUDOK_TOKEN", ""))
    parser.add_argument("--p1", default="Ninja")
    parser.add_argument("--p2", default="Cowboy")
    parser.add_argument("--hp", type=int, default=300, help="starting HP (keeps the test short)")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    random.seed(args.seed)
    problems: list[str] = []

    with BudokClient(args.url, args.token, timeout=120) as client:
        status = client.call("get_status")
        print(f"budok {status['budok_version']} on game {status['game_version']}")
        names = [c["name"] for c in client.call("list_characters")["characters"]]
        print("characters:", ", ".join(names))
        for wanted in (args.p1, args.p2):
            if wanted not in names:
                print(f"error: {wanted} is not available")
                return 1
        client.call("start_match", {"p1": args.p1, "p2": args.p2, "controllers": {"p1": "mcp", "p2": "mcp"},
                                    "claim": "both", "starting_hp": args.hp})
        print(f"match started: {args.p1} vs {args.p2} at {args.hp} HP")
        simulated = submitted = 0
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            match = client.call("get_status")["match"]
            if match.get("last_result"):
                result = match["last_result"]
                print(f"result: {result['winner']} wins at tick {result['end_tick']} (hp {result['hp']})")
                break
            views = {}
            for slot in ("p1", "p2"):
                view = client.call("get_turn", {"slot": slot})
                if view.get("turn_token"):
                    views[slot] = view
            if not views:
                time.sleep(0.2)
                continue
            for slot, view in views.items():
                legal = [a["action"] for a in view["legal_actions"]]
                attacks = [a["action"] for a in view["legal_actions"] if a["type"] in ("Attack", "Special")] or legal
                action = random.choice(attacks)
                if simulated < 3:
                    try:
                        preview = client.call("simulate", {"slot": slot, "action": action})
                        print(f"simulate {slot} {action}: {preview['summary']}")
                        simulated += 1
                    except McpError as error:
                        problems.append(f"simulate {action}: {error}")
                try:
                    client.call("submit_action", {"turn_token": view["turn_token"], "action": action, "wait_for_outcome": False})
                    submitted += 1
                except McpError as error:
                    if "already_submitted" not in str(error) and "stale_turn" not in str(error):
                        problems.append(f"submit {action}: {error}")
        else:
            problems.append("match did not finish within 15 minutes")
        log = client.call("get_match_log", {"last_n": 3})
        print("last turns:", log["history"])
    print(f"{submitted} moves submitted, {simulated} simulations")
    if problems:
        print("PROBLEMS:")
        for problem in problems:
            print(" -", problem)
        return 1
    print("self-test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
