#!/bin/bash

set -uo pipefail

cd "$(dirname "$0")/.."

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="benchmarks/simple-${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

PROXY_IP=$(cd terraform && terraform output -raw proxy_public_ip)
echo "Simple benchmark sweep -> $RESULTS_DIR"
echo "Proxy: $PROXY_IP"
echo "Start: $(date)"
echo

for N in 1 2 3 4 5; do
    echo "========================================================"
    echo "  N=$N nodes  $(date '+%H:%M:%S')"
    echo "========================================================"
    echo "$N" > servers.conf

    T0=$(date +%s)
    if ! ./install ~/open/as2-openrc.sh raghu ~/.ssh/nso_key \
            > "$RESULTS_DIR/install-n${N}.log" 2>&1; then
        echo "  install failed -- retrying once after 60s"
        sleep 60
        if ! ./install ~/open/as2-openrc.sh raghu ~/.ssh/nso_key \
                >> "$RESULTS_DIR/install-n${N}.log" 2>&1; then
            echo "  second attempt failed -- skipping N=$N"
            continue
        fi
    fi
    T1=$(date +%s)
    ELAPSED=$((T1 - T0))
    echo "  deployed in ${ELAPSED}s"
    echo "$ELAPSED" > "$RESULTS_DIR/deploy-time-n${N}.txt"

    for i in $(seq 1 5); do
        curl -s --max-time 5 -o /dev/null "http://$PROXY_IP:5000/" || true
    done
    sleep 5

    echo "  --- c=10 n=1000 ---"
    for RUN in 1 2 3; do
        printf "    run %d/3  %s  " "$RUN" "$(date '+%H:%M:%S')"
        ab -n 1000 -c 10 -s 30 \
           "http://$PROXY_IP:5000/" \
           > "$RESULTS_DIR/ab-n${N}-run${RUN}.txt" 2>&1 \
           && STATUS=ok || STATUS=partial
        printf "%s  " "$STATUS"
        grep "^Total:" "$RESULTS_DIR/ab-n${N}-run${RUN}.txt" \
            | awk '{printf "mean=%sms sd=%s\n", $3, $4}' \
            || echo "(aborted)"
        sleep 3
    done
    echo
done

echo "========================================================"
echo "Sweep complete: $(date)"
echo "Results: $RESULTS_DIR"
echo "========================================================"
