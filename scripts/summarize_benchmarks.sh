#!/bin/bash
# Pulls Total Connection Time mean and sd from each ab output
# and prints a CSV table averaging across the 3 runs per N.

DIR="${1:-$(ls -td benchmarks/2026* | head -1)}"
echo "Source: $DIR"
echo
echo "N,deploy_s,mean_total_ms,sd_total_ms"
for N in 1 2 3 4 5; do
    DEPLOY=$(cat "$DIR/deploy-time-n${N}.txt" 2>/dev/null || echo "?")
    # Extract the "Total:" line from each run, take the mean (col 3) and sd (col 4)
    MEANS=()
    SDS=()
    for RUN in 1 2 3; do
        line=$(grep '^Total:' "$DIR/ab-n${N}-run${RUN}.txt" | head -1)
        # Total:         38   72  90.0     64    1110
        # cols:           min mean sd       median max
        m=$(echo "$line" | awk '{print $3}')
        s=$(echo "$line" | awk '{print $4}')
        MEANS+=("$m"); SDS+=("$s")
    done
    AVG_M=$(echo "${MEANS[@]}" | awk '{ sum=0; for(i=1;i<=NF;i++) sum+=$i; printf "%.1f", sum/NF }')
    AVG_S=$(echo "${SDS[@]}"   | awk '{ sum=0; for(i=1;i<=NF;i++) sum+=$i; printf "%.1f", sum/NF }')
    echo "${N},${DEPLOY},${AVG_M},${AVG_S}"
done
