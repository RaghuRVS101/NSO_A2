#!/bin/bash
# Phase 9 benchmark sweep.
# For N in 1..5: set servers.conf=N, redeploy, ab x 3.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
PROXY_IP=$(cd terraform && terraform output -raw proxy_public_ip)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="benchmarks/$TIMESTAMP"
mkdir -p "$RESULTS_DIR"

# ab parameters
REQUESTS=1000
CONCURRENCY=10

echo "Starting benchmark sweep at $(date)"
echo "Proxy: $PROXY_IP"
echo "Results will be saved to $RESULTS_DIR"
echo "ab parameters: -n $REQUESTS -c $CONCURRENCY"
echo

for N in 1 2 3 4 5; do
    echo "================================================================"
    echo "=== Setting up $N node(s) at $(date '+%H:%M:%S') ==="
    echo "================================================================"
    echo "$N" > servers.conf

    DEPLOY_START=$(date +%s)
    ./install ~/open/as2-openrc.sh raghu ~/.ssh/nso_key > "$RESULTS_DIR/install-n${N}.log" 2>&1
    DEPLOY_END=$(date +%s)
    echo "Deployment to $N nodes took $((DEPLOY_END - DEPLOY_START)) seconds"
    echo "$((DEPLOY_END - DEPLOY_START))" > "$RESULTS_DIR/deploy-time-n${N}.txt"

    # Warmup — first request after deploy can be slow
    echo "Warmup..."
    for i in 1 2 3 4 5; do
        curl -s --max-time 5 -o /dev/null "http://$PROXY_IP:5000/" || true
    done
    sleep 5

    for RUN in 1 2 3; do
        echo "--- ab run $RUN of 3 for N=$N at $(date '+%H:%M:%S') ---"
        ab -n $REQUESTS -c $CONCURRENCY "http://$PROXY_IP:5000/" \
           > "$RESULTS_DIR/ab-n${N}-run${RUN}.txt" 2>&1
        # Show just the connection times block from this run
        sed -n '/Connection Times/,/Percentage/p' "$RESULTS_DIR/ab-n${N}-run${RUN}.txt" | head -10
        sleep 3
    done
done

echo
echo "================================================================"
echo "Sweep done at $(date). Results in $RESULTS_DIR"
echo "================================================================"
