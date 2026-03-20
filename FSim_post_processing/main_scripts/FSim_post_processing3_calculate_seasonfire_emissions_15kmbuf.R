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
  make_option(c("-a", "--study_area_polygon"), type="character", default=NULL,
              help="study area polygon for summary (mandatory)", metavar="character")
)
# parse the command-line options
opt_parser = OptionParser(option_list=option_list)
opt = parse_args(opt_parser)

#######################################################################################
# NOTE: To run this code, you need to make sure the following FSim outputs are in the #
#       working directory: the FireSizeList.csv files and the SeasonFires_merged_tifs #
#       directory.                                                                    #
#######################################################################################

#STEP 1: Record run information below 
###############################################
# Set the optparse variables as local variables to then pass to furr_options() for parallelization
foa_run <- opt$foa_run
scenario <- opt$scenario
run_timepoint <- opt$run_timepoint

#Set the working directory to the specific outputs folder for the run
setwd(opt$working_directory)
wd <- getwd()

# Create the output directory
out_dir <- paste0("./SeasonFires_effects_tifs_", scenario, "_", run_timepoint, "/")
dir.create(out_dir, showWarnings = FALSE)

#STEP 2: Add estimated emissions to the SeasonFire stack
#############################################################
tif_files <- list.files(opt$season_fires_directory, pattern = "\\.tif$", full.names=TRUE)
#convert to absolute paths
tif_files <- normalizePath(tif_files)

# Set up parallel backend for a Linux cluster
# Use `multicore` for single-node, or `cluster` with specified workers for multi-node
# Replace `<number_of_cores>` with the number of cores available
plan(multisession) # Or plan(cluster, workers = <number_of_cores>)

# Specify log file path
log_file <- paste0("./SeasonFire_15km_summary_emissions_log_", foa_run, "_", scenario, ".log")

# Helper function to log messages to the log file
log_message <- function(message) {
  cat(message, "\n", file = log_file, append = TRUE)
}

log_message(paste0("Processing began at ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))

# Define the processing function for a single tif
process_tif <- function(tif) {
  # Extract the season number from the filename using a regular expression
  season_number <- as.integer(
    stringr::str_extract(basename(tif), "(?<=Season)[0-9]+")
  )

  if (is.na(season_number)) {
    stop(paste("Failed to parse season from:", tif))
  }
    
  # Load the SeasonFire raster stack - we need all three layers
  season_stack <- rast(tif)
  # Load the study area polygon and use it to crop the raster
  okawen_15km_buf <- terra::vect(opt$study_area_polygon)
  season_stack <- terra::crop(season_stack, okawen_15km_buf, mask=TRUE)
    
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
  epm_stack <- crop(epm_stack, okawen_15km_buf, mask=TRUE)
  season_epm_stack <- epm_stack * fl_binary_stack
  season_epm <- sum(season_epm_stack, na.rm=TRUE)
  
  # Append to the season stack
  season_stack <- crop(season_stack, season_epm)
  season_stack <- c(season_stack, season_epm)
  pixel_area <- prod(res(season_stack))
  
  #We'll need emissions in kg
  # EPM (kg) = EPM (ton/acre) * (907.185 kg / 1 ton)*(1 acre /4046.86 m2)*(pixel_area_m2)*(number of pixels)
  season_stack[[4]] <- terra::app(season_stack[[4]], fun=function(i)i*907.185 / 4046.86*pixel_area)
  names(season_stack[[4]]) <- "ePM_kg"
  
  # Extract the FireID, ArrivalDay, and ePM bands
  # Do this before converting EPM so that you hae ePM in tonnes/acre and in kg in the summary csv
  vals <- values(season_stack[[c(1,2,4)]], dataframe=TRUE)
  names(vals) <- c("FireID","JulianDay","ePM_kg")
  vals <- vals[!is.na(vals$JulianDay), ]

 if (nrow(vals) == 0) {
    return(data.frame(
      Season = season_number,
      JulianDay = NA,
      num_active_fires = 0,
      num_pixels_burned = 0,
      area_burned_m2 = 0,
      daily_ePM_kg = 0
    ))
  }
     
  daily_summary <- vals %>%
  group_by(JulianDay) %>%
  summarise(
    num_active_fires = n_distinct(FireID),
    num_pixels_burned = n(),
    area_burned_m2 = n()*pixel_area,
    daily_ePM_kg = sum(ePM_kg, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(JulianDay) %>%
  mutate(Season = season_number) %>%
  relocate(Season)

  daily_summary
}

# Apply the processing function in parallel to each tif file
daily_ePM_summary <- future_map_dfr(tif_files, process_tif)

# Write the results to CSV
output_path <- paste0("./SeasonFire_emissions_15km_summary_", foa_run, "_", scenario, "_", opt$run_timepoint, ".csv")
write_csv(daily_ePM_summary, output_path)

# Clean up parallel backend
plan(sequential)

log_message(paste0("Processing ended at ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
