library(tidyverse)
library(raster)
library(terra)
library(tidyterra)
library(RSQLite)
library(furrr)
library(optparse)

#Set up input arguments with optparse
option_list = list(
  make_option(c("-w", "--working_directory"), type="character", default=NULL,
              help="working directory (mandatory)", metavar="character"),
  make_option(c("-f", "--season_fires_directory"), type="character", default=NULL,
              help="season fires directory (mandatory)", metavar="character"),
  make_option(c("-r", "--foa_run"), type="character", default=NULL,
              help="foa run label (mandatory)", metavar="character"),
  make_option(c("-s", "--scenario"), type="character", default=NULL,
              help="project scenario (mandatory)", metavar="character"),
  make_option(c("-t", "--run_timepoint"), type="character", default=NULL,
              help="timepoint for the scenario (mandatory)", metavar="character"),
  make_option(c("-n", "--number_of_seasons"), type="integer", default=NULL,
              help="total number of seasons (mandatory)", metavar="integer"),
  make_option(c("--seasons_in_part"), type="integer", default=NULL,
              help="number of seasons in a part", metavar="integer"),
  make_option(c("--number_of_parts"), type="integer", default=NULL,
              help="number of run parts", metavar="integer"),
  make_option(c("-j", "--seasons_per_part"), type="character", default=NULL,
              help="vector of number of seasons in a part", metavar="character")
)
# parse the command-line options
opt_parser = OptionParser(option_list=option_list)
opt = parse_args(opt_parser)

#Set the working directory to the specific outputs folder for the run
setwd(opt$working_directory)
wd <- getwd()

#######################################################################################
# NOTE: To run this code, you need to make sure the following FSim outputs are in the #
#       working directory: the FireSizeList.csv files and the SeasonFires_merged_tifs #
#       directory.                                                                    #
#######################################################################################

#STEP 1: Record run information below 
###############################################
# calculate or parse seasons_per_part
if (is.null(opt$seasons_per_part)) {
  seasons_per_part <- rep(opt$seasons_in_part, opt$number_of_parts)
} else {
  seasons_per_part <- as.integer(unlist(strsplit(opt$seasons_per_part, ",")))
}
# Set the optparse variables as local variables to then pass to furr_options() for parallelization
foa_run <- opt$foa_run
scenario <- opt$scenario
run_timepoint <- opt$run_timepoint

# Create the output directory
out_dir <- paste0("./SeasonFires_effects_tifs_", scenario, "_", run_timepoint)
dir.create(out_dir, showWarnings = FALSE)

#STEP 2: Add estimated emissions to the SeasonFire stack
#############################################################
tif_files <- list.files(opt$season_fires_directory, pattern = "\\.tif$", full.names=TRUE)

# Set up parallel backend for a Linux cluster
# Use `multicore` for single-node, or `cluster` with specified workers for multi-node
# Replace `<number_of_cores>` with the number of cores available
plan(multisession) # Or plan(cluster, workers = <number_of_cores>)

# Specify log file path
log_file <- paste0("./SeasonFire_emissions_log_", foa_run, "_", scenario, ".log")

# Helper function to log messages to the log file
log_message <- function(message) {
  cat(message, "\n", file = log_file, append = TRUE)
}

# Define the processing function for a single tif
process_tif <- function(tif) {
  # Extract the season number from the filename using a regular expression
  season_number <- as.numeric(sub(".*Season([0-9]+)_.*", "\\1", basename(tif)))
  log_message(paste0("Processing season ", season_number, "..."))
  
  # Load the SeasonFire raster stack - we need all three layers
  season_stack <- rast(tif)
  
  # Classify flame lengths
  fl <- season_stack[[3]]
  
  fl_binary_stack <- c(
    fl <= 2,
    fl > 2 & fl <= 4,
    fl > 4 & fl <= 6,
    fl > 6 & fl <= 8,
    fl > 8 & fl <= 12,
    fl > 12
  )
  
  # Convert to a stack of six binary rasters (1 where flame length category occurred)
  
  # Multiply by expected emissions rasters
  # The directory will live in the parent folder - the scenario folder within which the FSim and FVS runs will occur
  fx_dir <- paste0("../", scenario, "_", run_timepoint, "_firefx/")
  # Grab ePM raster stack
  epm_path <- list.files(fx_dir, pattern="ePM",
                         full.names = TRUE)
  epm_stack <- rast(epm_path)
  
  # Multiply the ePM stack by the binary FL rasters
  season_epm_stack <- epm_stack * fl_binary_stack
  season_epm <- sum(season_epm_stack, na.rm=TRUE)
  # Append to the season stack
  season_stack <- c(season_stack, season_epm)
  # Write to a new directory; if successful you can delete the old directory
  writeRaster(season_stack, paste0("./SeasonFires_effects_tifs_", scenario, "_", run_timepoint,"/Season", season_number,"_merged_IDs_ADs_FLs_ePM.tif"))
 
  # Extract the FireID, ArrivalDay, and ePM bands
  vals <- values(season_stack[[c(1,2,4)]], dataframe=TRUE, na.rm=TRUE)
  names(vals) <- c("FireID","JulianDay","ePM")
  
  #We'll need emissions in kg
  # EPM (kg) = EPM (ton/acre) * (907.185 kg / 1 ton)*(1 acre /4046.86 m2)*(pixel_area_m2)*(number of pixels)
  pixel_area <- prod(res(season_stack))
  
  daily_summary <- df %>%
    group_by(JulianDay) %>%
    summarise(
      num_active_fires = n_distinct(FireID),
      num_pixels_burned = n(),
      area_burned_m2 = n()*pixel_area,
      daily_ePM_tonnes_per_acre = sum(ePM, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(JulianDay) %>%
    mutate(Season = season_number) %>%
    relocate(Season) %>%
    mutate(daily_ePM_kg = daily_ePM_tonnes_per_acre * 907.185 / 4046.86 * area_burned_m2)
  
  daily_summary
}

# Apply the processing function in parallel to each tif file
daily_ePM_summary <- future_map_dfr(tif_files, process_tif)



# Write the results to CSV
output_path <- paste0("./emissions_num_fires_area_burned_by_season_", foa_run, "_", scenario, "_", opt$run_timepoint, ".csv")
write_csv(daily_ePM_summary, output_path)

# Clean up parallel backend
plan(sequential)
