#!/bin/bash

# Usage: ./generate_calculate_seasonfire_emissions_scripts_SCINet.sh <study_area> <foa_run> <scenario> <run_timepoint> <job_name>

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <study_area> <foa_run> <scenario> <run_timepoint> <job_name>"
    exit 1
fi

study_area=$1
foa_run=$2
scenario=$3
run_timepoint=$4
job_name=$5

output_dir="/project/wildland_fire_smoke_tradeoff/${study_area}_${foa_run}_${scenario}_${run_timepoint}"
script_name="${study_area}_${foa_run}_${scenario}_${run_timepoint}_calc_seasonfire_epm.sh"

cat > "$script_name" <<EOL
#!/bin/bash
# Note: Before running this on Linux, you'll need to run this line to remove stupid Windows characters:
# sed -i -e 's/\r$//' rename_tifs.sh

#SBATCH --job-name=${job_name}
#SBATCH --account=wildland_fire_smoke_tradeoff
#SBATCH --partition=ceres
#SBATCH --time=02-00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=96
#SBATCH --output=${output_dir}/_error/${foa_run}_pt${part}_${scenario}_${run_timepoint}_calc_emissions_slurmlog_%A.out
#SBATCH --error=${output_dir}/_error/${foa_run}_pt${part}_${scenario}_${run_timepoint}_calc_emissions_error_%A.log
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
/home/laurel.sindewald/.conda/envs/r_env2/bin/Rscript FSim_post_processing3_calculate_seasonfire_emissions.R \\
--working_directory ${output_dir}/ \\
--season_fires_directory ./SeasonFires_merged_tifs_${scenario}_${run_timepoint}/ \\
--foa_run ${foa_run} \\
--scenario ${scenario} \\
--run_timepoint ${run_timepoint} 
EOL

echo "Generated SLURM script to calculate seasonfire emissions rasters for ${study_area} ${foa_run}, scenario ${scenario}, run timepoint ${run_timepoint}."
