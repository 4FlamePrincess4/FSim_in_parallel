#!/bin/bash

## This is code to run the script that launches FSim within the firemodels.sif container

#SBATCH --job-name=F122ROp1
#SBATCH --account=wildland_fire_smoke_tradeoff
#SBATCH --partition=ceres
#SBATCH --time=07-00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=96
#SBATCH --hint=nomultithread
#SBATCH --mail-user=laurel.sindewald@usda.gov
#SBATCH --mail-type=BEGIN
#SBATCH --mail-type=END
#SBATCH --mail-type=FAIL
#SBATCH --output=/project/wildland_fire_smoke_tradeoff/okwen_foa1c_r16_LF2022_RecOff3_2/_error/foa1c_r16_pt1_LF2022_RecOff3_2_slurmlog_%A.out
#SBATCH --error=/project/wildland_fire_smoke_tradeoff/okwen_foa1c_r16_LF2022_RecOff3_2/_error/foa1c_r16_pt1_LF2022_RecOff3_2_error_%A.log

module load apptainer

singularity exec /project/wildland_fire_smoke_tradeoff/firemodels.sif ./RunFSim_foa1c_r16_pt1_LF2022_RecOff3_2.sh
