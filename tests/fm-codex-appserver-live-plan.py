"""Scenario selection for the opt-in Codex app-server canary."""
import argparse

SCENARIOS = ('scout-success', 'scout-failure', 'scout-interrupt')


def parse_scenarios(args):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--scenario', action='append', choices=SCENARIOS)
    options, unknown = parser.parse_known_args(args)
    if unknown:
        parser.error('unrecognized arguments: ' + ' '.join(unknown))
    if not options.scenario:
        return None
    return tuple(name for name in SCENARIOS if name in set(options.scenario))


def selected(name, scenarios):
    return scenarios is None or name in scenarios
