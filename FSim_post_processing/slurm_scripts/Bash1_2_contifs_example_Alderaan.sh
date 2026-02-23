#!/bin/bash
# Note: Before running this on Linux, you'll need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' rename_tifs.sh

#SBATCH --job-name=116conti
#SBATCH --partition=math-alderaan
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --output=FOA1c_r16_2016_comb_AD_tifs_slurmlog_%A.out
#SBATCH --error=FOA1c_r16_2016_comb_AD_tifs_error_%A.log
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=laurel.sindewald@ucdenver.edu

# Change to the directory containing your R script
cd /data001/projects/sindewal/FSim_post_processing/
# Make a directory to hold the merged tifs
mkdir ../okwen_foa1c_r16_LF2016/SeasonFires_merged_tifs_LF2016/

# Activate conda environment 
source /data001/projects/sindewal/anaconda3/bin/activate r_env2

# Run the R script
/data001/projects/sindewal/anaconda3/envs/r_env2/bin/Rscript FSim_post_processing1_2_merge_fire_tifs_v11_2_Scenario_refact_of_the_Nordgren.R \
--foa_lcp_path ./_inputs/lcp/lf2019_200_foa1c_120m.tif \
--working_directory /data001/projects/sindewal/okwen_foa1c_r16_LF2016/ \
--foa_run foa1c_r16 \
--scenario LF2016 \
--run_timepoint baseline_time0 \
--number_of_seasons 20000 \
--seasons_in_part 5000 \
--number_of_parts 4 \
--first_season 1 \
--last_season 20000 \
--merge_fires_part LF2016_total
