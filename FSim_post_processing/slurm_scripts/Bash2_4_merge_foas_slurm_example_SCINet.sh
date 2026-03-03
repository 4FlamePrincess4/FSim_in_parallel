#!/bin/bash
#Note: before running on Linux, you may need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' merge_run_parts_slurm_template.sh

#SBATCH --job-name=122RO3_merge_foas
#SBATCH --account=wildland_fire_smoke_tradeoff
#SBATCH --partition=ceres
#SBATCH --time=02-00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=96
#SBATCH --output=/project/wildland_fire_smoke_tradeoff/okwen_foa1c_r16_LF2022_RecOff3/foa1c_r16_LF2022_RecOff3_merge_foas_slurmlog_%A.out
#SBATCH --error=/project/wildland_fire_smoke_tradeoff/okwen_foa1c_r16_LF2022_RecOff3/foa1c_r16_LF2022_RecOff3_merge_foas_error_%A.log
#SBATCH --mail-user=laurel.sindewald@usda.gov
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-type=FAIL

#Change to the directory containing your R script
cd /project/wildland_fire_smoke_tradeoff/FSim_post_processing/

#Activate conda environment
module load miniconda
source activate r_env2

#Run the R script
/home/laurel.sindewald/.conda/envs/r_env2/bin/Rscript FSim_post_processing2_4_merge_FOAs.R \
--working_directory /project/wildland_fire_smoke_tradeoff/ \
--scenario LF2022_RecOff3 \
--run_timepoint time2 \
--foa_seasons_csv /project/wildland_fire_smoke_tradeoff/foa_seasons.csv \
--study_area_lcp ./study_area_lcps/LF2020_220_OKAWEN_Colville_LCP_120m.tif
