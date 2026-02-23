#!/bin/bash

# Usage: ./generate_contifs_scripts_SCINet.sh <study_area> <foa_run> <scenario> <run_timepoint> <job_name> <num_seasons> <seasons_in_part> <num_parts> <foa_lcp>

if [ "$#" -ne 9 ]; then
    echo "Usage: $0 <study_area> <foa_run> <scenario> <run_timepoint> <job_name> <num_seasons> <seasons_in_part> <num_parts> <foa_lcp>"
    exit 1
fi

study_area=$1
foa_run=$2
scenario=$3
run_timepoint=$4
job_name=$5
num_seasons=$6
seasons_in_part=$7
num_parts=$8
foa_lcp=$9

output_dir="/project/wildland_fire_smoke_tradeoff/${study_area}_${foa_run}_${scenario}_${run_timepoint}"
script_name="${study_area}_${foa_run}_${scenario}_${run_timepoint}_contifs.sh"

cat > "$script_name" <<EOL
#!/bin/bash
# Note: Before running this on Linux, you'll need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' rename_tifs.sh

#SBATCH --job-name=${job_name}
#SBATCH --account=wildland_fire_smoke_tradeoff
#SBATCH --partition=ceres
#SBATCH --time=04-00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=96
#SBATCH --output=${output_dir}/_error/${foa_run}_pt${part}_${scenario}_${run_timepoint}_comb_tifs_slurmlog_%A.out
#SBATCH --error=${output_dir}/_error/${foa_run}_pt${part}_${scenario}_${run_timepoint}_comb_tifs_error_%A.log
#SBATCH --mail-user=laurel.sindewald@usda.gov
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-type=FAIL

# Change to the directory containing your R script
cd /project/wildland_fire_smoke_tradeoff/FSim_post_processing/
# Make a directory to hold the merged tifs
mkdir ${output_dir}/SeasonFires_merged_tifs_${scenario}_${run_timepoint}/

# Activate conda environment
module load miniconda
source activate r_env2

# Run the R script
/home/laurel.sindewald/.conda/envs/r_env2/bin/Rscript FSim_post_processing1_2_merge_fire_tifs_v11_2_Scenario_refact_of_the_Nordgren.R \\
--foa_lcp_path ${foa_lcp} \\
--working_directory ${output_dir} \\
--foa_run ${foa_run} \\
--scenario ${scenario} \\
--run_timepoint ${run_timepoint} \\
--number_of_seasons ${num_seasons} \\
--seasons_in_part ${seasons_in_part} \\
--number_of_parts ${num_parts} \\
--first_season 1 \\
--last_season 20000 \\
--merge_fires_part ${scenario}_${run_timepoint}
EOL

echo "Generated SLURM script to combine tifs (and delete overburn) for ${study_area} ${foa_run}, scenario ${scenario}, run timepoint ${run_timepoint}."
