#!/bin/bash
# Note: Before running this on Linux, you'll need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' rename_tifs.sh

#SBATCH --job-name=120cemis
#SBATCH --partition=math-alderaan
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --mem-per-cpu=4096
#SBATCH --output=/data001/projects/sindewal/okawen_foa1c_r16_LF2020_ME_S3_RO/_error/foa1c_r16_LF2020_ME_S3_RO_calc_seasonfire_emissions_slurmlog_%A.out
#SBATCH --error=/data001/projects/sindewal/okawen_foa1c_r16_LF2020_ME_S3_RO/_error/foa1c_r16_LF2020_ME_S3_RO_calc_seasonfire_emissions1c_r16_2016_overburn_summary_error_%A.log
#SBATCH --mail-user=laurel.sindewald@ucdenver.edu
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-type=FAIL

# Change to the directory containing your R script
cd /data001/projects/sindewal/FSim_in_parallel/FSim_post_processing/main_scripts

# Activate conda environment 
source /data001/projects/sindewal/anaconda3/bin/activate r_env2

# Run the R script
/data001/projects/sindewal/anaconda3/envs/r_env2/bin/Rscript FSim_post_processing3_calculate_seasonfire_emissions.R \
--working_directory /data001/projects/sindewal/okawen_foa1c_r16_LF2020_ME_S3_RO/ \
--season_fires_directory ./SeasonFires_merged_tifs_LF2020_ME_S3_RO/ \
--foa_run foa1c_r16 \
--scenario LF2020 \
--run_timepoint ME_S3_RO 
