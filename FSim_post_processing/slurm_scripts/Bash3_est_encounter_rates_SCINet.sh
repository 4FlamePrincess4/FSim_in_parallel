#!/bin/bash
# Note: Before running this on Linux, you'll need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' rename_tifs.sh

#SBATCH --job-name=1ME1encr
#SBATCH --partition=ceres
#SBATCH --time=04-00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=96
#SBATCH --output=/project/wildland_fire_smoke_tradeoff/okawen_foa1c_r16_LF2020_ME_S1_RO/_error/foa1c_r16_LF2020_ME_S1_RO_est_tx_encounter_rate_slurmlog_%A.out
#SBATCH --error=/project/wildland_fire_smoke_tradeoff/okawen_foa1c_r16_LF2020_ME_S1_RO/_error/foa1c_r16_LF2020_ME_S1_RO_est_tx_encounter_rate_error_%A.log
#SBATCH --mail-user=laurel.sindewald@usda.gov
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-type=FAIL


# Change to the directory containing your R script
cd /project/wildland_fire_smoke_tradeoff/FSim_post_processing/

# Activate conda environment
module load miniconda
source activate r_env2

# Run the R script
/home/laurel.sindewald/.conda/envs/r_env2/bin/Rscript FSim_post_processing3_summarize_treatment_encounter_rates.R \
--working_directory /data001/projects/sindewal/okawen_foa1c_r16_LF2020_ME_S1_RO/ \
--season_fires_directory ./SeasonFires_effects_tifs_LF2020_ME_S1_RO/ \
--foa_run foa1c_r16 \
--scenario LF2020 \
--run_timepoint ME_S1_RO \
--study_area_polygon ./OkaWen_boundary_15km_buffer/OkaWen_boundary_15km_buffer.shp \
--fdist_raster ./Rxfire27p_Dist111_Treatment.tif
