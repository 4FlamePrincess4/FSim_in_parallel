#!/bin/bash

# Usage: ./generate_FSim_scripts.sh <foa_run> <scenario> <run_timepoint> <num_parts> <study_area>

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <foa_run> <scenario> <run_timepoint> <num_parts> <study_area>"
    exit 1
fi

foa_run=$1
scenario=$2
run_timepoint=$3
num_parts=$4
study_area=$5

for part in $(seq 1 $num_parts); do
    script_name="RunFSim_${foa_run}_pt${part}_${scenario}_${run_timepoint}.sh"
    cmdx_filename="${foa_run}_pt${part}_${scenario}_${run_timepoint}.cmdx"
    version_filename="${foa_run}_pt${part}_${scenario}_${run_timepoint}_version.txt"
    captainslog_name="${foa_run}_pt${part}_${scenario}_${run_timepoint}_captainslog.txt"
    
    cat > "$script_name" <<EOL
#!/bin/bash

cd ..
fsim > ${version_filename}
fsim ${cmdx_filename} >> ${captainslog_name}
EOL

done

echo "Generated $num_parts FSim run scripts for ${study_area} ${foa_run}, scenario ${scenario}, run timepoint ${run_timepoint}."
