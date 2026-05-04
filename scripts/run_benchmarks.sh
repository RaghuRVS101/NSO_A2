#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
PROXY_IP=$(cd terraform && terraform output -raw proxy_public_ip)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="benchmarks/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

# Three load profiles: requests scale with concurrency to keep run time bounded.
declare -A REQUESTS
REQUESTS[10]=1000
REQUESTS[50]=5000
REQUESTS[100]=10000

CONCURRENCIES="10 50 100"

echo "Starting multi-concurrency sweep at $(date)"
echo "Proxy: $PROXY_IP"
echo "Results: $RESULTS_DIR"
echo

for N in 1 2 3 4 5; do
    echo "================================================================"
    echo "=== Setting up $N node(s) at $(date '+%H:%M:%S') ==="
    echo "================================================================"
    echo "$N" > servers.conf

    DEPLOY_START=$(date +%s)
    ./install ~/open/as2-openrc.sh raghu ~/.ssh/nso_key > "$RESULTS_DIR/install-n${N}.log" 2>&1
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
        echo "--- N=$N concurrency=$C requests=$N_REQ ---"
        for RUN in 1 2 3; do
            echo "    run $RUN of 3 at $(date '+%H:%M:%S')"
            ab -n $N_REQ -c $C "http://$PROXY_IP:5000/" \
               > "$RESULTS_DIR/ab-n${N}-c${C}-run${RUN}.txt" 2>&1
            sed -n '/Connection Times/,/Percentage/p' \
                "$RESULTS_DIR/ab-n${N}-c${C}-run${RUN}.txt" | head -7
            sleep 3
        done
    done
done

echo
echo "================================================================"
echo "Sweep done at $(date). Results in $RESULTS_DIR"
echo "================================================================"
