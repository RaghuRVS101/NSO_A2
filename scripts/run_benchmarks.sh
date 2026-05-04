#!/bin/bash
set -uo pipefail

START=1
if [ "${1:-}" = "--start" ] && [ -n "${2:-}" ]; then
    START="$2"
fi

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
PROXY_IP=$(cd terraform && terraform output -raw proxy_public_ip)


if [ "$START" -gt 1 ]; then
    RESULTS_DIR=$(ls -td benchmarks/2026* | head -1)
    echo "Resuming sweep in $RESULTS_DIR (starting at N=$START)"
else
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    RESULTS_DIR="benchmarks/$TIMESTAMP"
    mkdir -p "$RESULTS_DIR"
    echo "Starting fresh sweep at $(date) in $RESULTS_DIR"
fi
echo "Proxy: $PROXY_IP"

declare -A REQUESTS
REQUESTS[10]=1000
REQUESTS[50]=5000
REQUESTS[100]=10000

CONCURRENCIES="10 50 100"

for N in $(seq "$START" 5); do
    echo "================================================================"
    echo "=== Setting up $N node(s) at $(date '+%H:%M:%S') ==="
    echo "================================================================"
    echo "$N" > servers.conf

    DEPLOY_START=$(date +%s)
    if ! ./install ~/open/as2-openrc.sh raghu ~/.ssh/nso_key > "$RESULTS_DIR/install-n${N}.log" 2>&1; then
        echo "  install failed for N=$N — see install-n${N}.log; skipping"
        continue
    fi
    DEPLOY_END=$(date +%s)
    echo "Deployment took $((DEPLOY_END - DEPLOY_START)) seconds"
    echo "$((DEPLOY_END - DEPLOY_START))" > "$RESULTS_DIR/deploy-time-n${N}.txt"

    echo "Warmup..."
    for i in 1 2 3 4 5; do
        curl -s --max-time 5 -o /dev/null "http://$PROXY_IP:5000/" || true
    done
    sleep 5

    for C in $CONCURRENCIES; do
        N_REQ=${REQUESTS[$C]}
        echo "--- N=$N c=$C n=$N_REQ ---"
        for RUN in 1 2 3; do
            echo "    run $RUN at $(date '+%H:%M:%S')"
            ab -n "$N_REQ" -c "$C" -s 30 "http://$PROXY_IP:5000/" \
               > "$RESULTS_DIR/ab-n${N}-c${C}-run${RUN}.txt" 2>&1 \
               || echo "    ab returned non-zero (saturation likely); continuing"
            tail -8 "$RESULTS_DIR/ab-n${N}-c${C}-run${RUN}.txt"
            sleep 5
        done
    done
done

echo
echo "Sweep done at $(date). Results in $RESULTS_DIR"
