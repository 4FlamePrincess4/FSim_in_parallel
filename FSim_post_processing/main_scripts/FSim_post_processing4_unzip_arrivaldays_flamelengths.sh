#!/bin/bash
#SBATCH --job-name=120unzip
#SBATCH --account=wildland_fire_smoke_tradeoff
#SBATCH --partition=ceres
#SBATCH --time=02-00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=96
#SBATCH --output=/project/wildland_fire_smoke_tradeoff/okawen_foa1c_r16_LF2020_ME_S5_RO/_error/unzip_slurmlog_%A.out
#SBATCH --error=/project/wildland_fire_smoke_tradeoff/okawen_foa1c_r16_LF2020_ME_S5_RO/_error/unzip_error_%A.log

set -euo pipefail

BASE_DIR="/project/wildland_fire_smoke_tradeoff/okawen_foa1c_r16_LF2020_ME_S5_RO"

shopt -s nullglob

# Loop through only ArrivalDays and FlameLengths zip files
for ZIP in "$BASE_DIR"/*{ArrivalDays,FlameLengths}.zip; do
    echo "Unzipping $ZIP"
    
    # Create output directory name (remove .zip)
    OUT_DIR="${ZIP%.zip}"
    
    # Make directory if it doesn't exist
    mkdir -p "$OUT_DIR"
    
    # Unzip with junk paths (-j)
    unzip -j "$ZIP" -d "$OUT_DIR"
done

echo "Selected unzips completed successfully."
exit 0
