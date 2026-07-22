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
              help="study area polygon for summary (mandatory)", metavar="character"),
  make_option(c("-d", "--fdist_raster"), type="character", default=NULL,
              help="path to Landfire FDist raster with treatment/severity/TSD codes (mandatory)", metavar="character")
)
# parse the command-line options
opt_parser = OptionParser(option_list=option_list)
opt = parse_args(opt_parser)

#######################################################################################
# NOTE: To run this code, you need to make sure the following FSim outputs are in the #
#       working directory: the FireSizeList.csv files and the SeasonFires_merged_tifs #
#       directory, plus a Landfire FDist raster for the study area.                   #
#                                                                                      #
# FDist code scheme (3-digit integer):                                                #
#   1st digit: treatment type   1 = fire (rx), 3 = mechanical                         #
#   2nd digit: severity         1 = low, 2 = moderate, 3 = high                       #
#   3rd digit: time since disturbance   1 = 0-2 yrs, 2 = 2-5 yrs, 3 = 5-10 yrs         #
#######################################################################################

#STEP 1: Record run information below
###############################################
foa_run <- opt$foa_run
scenario <- opt$scenario
run_timepoint <- opt$run_timepoint

#Set the working directory to the specific outputs folder for the run
setwd(opt$working_directory)
wd <- getwd()

#STEP 2: Summarize treatment encounter area for each fire in the SeasonFire stack
#############################################################
tif_files <- list.files(opt$season_fires_directory, pattern = "\\.tif$", full.names=TRUE)
tif_files <- normalizePath(tif_files)

# Set up parallel backend for a Linux cluster
plan(multisession) # Or plan(cluster, workers = <number_of_cores>)

# Specify log file path
log_file <- paste0("./SeasonFire_15km_summary_tx_encounter_log_", foa_run, "_", scenario, ".log")

log_message <- function(message) {
  cat(message, "\n", file = log_file, append = TRUE)
}

log_message(paste0("Processing began at ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))

# Define the processing function for a single tif
process_tif <- function(tif) {
  # Terra objects (SpatVector/SpatRaster) are pointers to C++ objects and can't
  # be exported to parallel workers, so the study area polygon and FDist raster
  # are loaded fresh inside each worker call
  okawen_15km_buf <- terra::vect(opt$study_area_polygon)
  fdist_master <- terra::rast(opt$fdist_raster)
  fdist_master <- terra::crop(fdist_master, okawen_15km_buf, mask = TRUE)

  # Extract the season number from the filename using a regular expression
  season_number <- as.integer(
    stringr::str_extract(basename(tif), "(?<=Season)[0-9]+")
  )

  if (is.na(season_number)) {
    stop(paste("Failed to parse season from:", tif))
  }

  # Load the SeasonFire raster stack - band 1 is FireID
  season_stack <- rast(tif)
  season_stack <- terra::crop(season_stack, okawen_15km_buf, mask = TRUE)
  fireid <- season_stack[[1]]
  names(fireid) <- "FireID"

  # Align the FDist raster to this tif's extent/resolution
  fdist <- terra::crop(fdist_master, ext(fireid))
  if (!terra::compareGeom(fireid, fdist, stopOnError = FALSE)) {
    fdist <- terra::resample(fdist, fireid, method = "near")
  }
  names(fdist) <- "FDist"

  # Guard against a tif that doesn't actually overlap the study area polygon -
  # crop(mask=TRUE) can return a zero-cell raster in that case, and values()
  # on a zero-cell raster doesn't always come back as a clean 0-row data.frame
  if (terra::ncell(fireid) == 0 || all(is.na(terra::minmax(fireid)))) {
    log_message(paste0("WARNING: no overlap / no fire pixels found for ", basename(tif),
                        " - skipping"))
    return(data.frame(
      Season = season_number,
      FireID = NA,
      mech_tx_area_km2 = 0,
      rxfire_tx_area_km2 = 0,
      total_area_km2 = 0,
      total_burned_area_km2 = 0,
      proportion_treated = NA
    ))
  }

  combined <- c(fireid, fdist)
  pixel_area_km2 <- prod(res(combined)) / 1e6

  # Total burned area per fire, based on FireID alone (independent of FDist overlap)
  fireid_vals <- values(fireid, dataframe = TRUE)
  fireid_vals <- fireid_vals[!is.na(fireid_vals$FireID), , drop = FALSE]

  if (NROW(fireid_vals) == 0) {
    return(data.frame(
      Season = season_number,
      FireID = NA,
      mech_tx_area_km2 = 0,
      rxfire_tx_area_km2 = 0,
      total_area_km2 = 0,
      total_burned_area_km2 = 0,
      proportion_treated = NA
    ))
  }

  burned_area_summary <- fireid_vals %>%
    group_by(FireID) %>%
    summarise(total_burned_area_km2 = n() * pixel_area_km2, .groups = "drop")

  vals <- values(combined, dataframe = TRUE)
  vals <- vals[!is.na(vals$FireID) & !is.na(vals$FDist), , drop = FALSE]

  if (NROW(vals) == 0) {
    return(burned_area_summary %>%
      mutate(
        Season = season_number,
        mech_tx_area_km2 = 0,
        rxfire_tx_area_km2 = 0,
        total_area_km2 = 0,
        proportion_treated = 0
      ) %>%
      relocate(Season, FireID, mech_tx_area_km2, rxfire_tx_area_km2, total_area_km2,
                total_burned_area_km2, proportion_treated))
  }

  vals <- vals %>%
    mutate(
      tx_type = case_when(
        FDist %/% 100 == 1 ~ "rxfire",
        FDist %/% 100 == 3 ~ "mech",
        TRUE ~ NA_character_
      )
    ) %>%
    filter(!is.na(tx_type))

  if (NROW(vals) == 0) {
    return(burned_area_summary %>%
      mutate(
        Season = season_number,
        mech_tx_area_km2 = 0,
        rxfire_tx_area_km2 = 0,
        total_area_km2 = 0,
        proportion_treated = 0
      ) %>%
      relocate(Season, FireID, mech_tx_area_km2, rxfire_tx_area_km2, total_area_km2,
                total_burned_area_km2, proportion_treated))
  }

  fire_summary <- vals %>%
    group_by(FireID, tx_type) %>%
    summarise(n_pixels = n(), .groups = "drop") %>%
    mutate(area_km2 = n_pixels * pixel_area_km2) %>%
    select(FireID, tx_type, area_km2) %>%
    pivot_wider(names_from = tx_type, values_from = area_km2, values_fill = 0)

  # Ensure both treatment columns exist even if one type never occurred this season
  if (!"mech" %in% names(fire_summary)) fire_summary$mech <- 0
  if (!"rxfire" %in% names(fire_summary)) fire_summary$rxfire <- 0

  # Fires with no treatment overlap won't appear in fire_summary at all, so
  # left-join onto the full burned_area_summary (every fire that burned this season)
  fire_summary <- burned_area_summary %>%
    left_join(fire_summary, by = "FireID") %>%
    rename(mech_tx_area_km2 = mech, rxfire_tx_area_km2 = rxfire) %>%
    mutate(
      mech_tx_area_km2 = replace_na(mech_tx_area_km2, 0),
      rxfire_tx_area_km2 = replace_na(rxfire_tx_area_km2, 0),
      total_area_km2 = mech_tx_area_km2 + rxfire_tx_area_km2,
      proportion_treated = if_else(total_burned_area_km2 > 0,
                                    total_area_km2 / total_burned_area_km2, NA_real_),
      Season = season_number
    ) %>%
    relocate(Season, FireID, mech_tx_area_km2, rxfire_tx_area_km2, total_area_km2,
              total_burned_area_km2, proportion_treated)

  fire_summary
}

# Apply the processing function in parallel to each tif file
tx_encounter_summary <- future_map_dfr(tif_files, process_tif)

# Write the results to CSV
output_path <- paste0("./SeasonFire_tx_encounter_15km_summary_", foa_run, "_", scenario, "_", opt$run_timepoint, ".csv")
write_csv(tx_encounter_summary, output_path)

# Clean up parallel backend
plan(sequential)

log_message(paste0("Processing ended at ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")))
