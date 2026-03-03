#!/bin/bash
#Note: before running on Linux, you may need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' merge_foas_slurm_template.sh

#SBATCH --job-name=MES3merg
#SBATCH --partition=math-alderaan
#SBATCH --nodes=1
#SBATCH --ntasks=64
#SBATCH --output=/data001/projects/sindewal/merge_outs/LF2020_ME_S3_merge_foas_slurmlog_%A.out
#SBATCH --error=/data001/projects/sindewal/merge_outs/LF2020_ME_S3_merge_foas_error_%A.log
#SBATCH --mail-user=laurel.sindewald@usda.gov
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-type=FAIL

#Change to the directory containing your R script
cd /data001/projects/sindewal/FSim_in_parallel/FSim_post_processing/main_scripts

#Activate conda environment
source /data001/projects/sindewal/anaconda3/bin/activate r_env2

#Run the R script
/data001/projects/sindewal/anaconda3/envs/r_env2/bin/Rscript FSim_post_processing2_4_merge_FOAs.R \
--working_directory /data001/projects/sindewal/ \
--scenario LF2020 \
--run_timepoint ME_S3 \
--foa_seasons_csv /data001/projects/sindewal/foa_seasons.csv \
--study_area_lcp ./study_area_lcps/LF2020_220_OKAWEN_Colville_LCP_120m.tif
