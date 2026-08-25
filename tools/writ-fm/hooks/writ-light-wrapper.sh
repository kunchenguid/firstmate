#!/usr/bin/env bash
# Wird nach ~/.local/bin/writ-light installiert.
# Ruft die venv-Installation mit absolutem Pfad auf — kein aktiviertes venv noetig.
exec /home/fridjof/projects/Rules/.venv/bin/writ-light "$@"
