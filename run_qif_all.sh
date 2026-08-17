for D in baseline qgsp; do
  for N in 64 128 256; do
    python qif_mi_fixed.py \
        --proxy  power_proxy_${D}_N${N}.npy \
        --labels labels_${D}_N${N}.npy      \
        --design $D --N $N
  done
done
