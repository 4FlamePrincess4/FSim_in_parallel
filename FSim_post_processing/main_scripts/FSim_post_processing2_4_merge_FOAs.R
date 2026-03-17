library(tidyverse)
library(terra)
library(optparse)

# Set up input arguments with optparse
option_list = list(
  make_option(c("-w", "--working_directory"), type="character", default=NULL,
              help="working directory (mandatory)", metavar="character"),
  make_option(c("-s", "--scenario"), type="character", default=NULL,
              help="project scenario (mandatory)", metavar="character"),
  make_option(c("-t", "--run_timepoint"), type="character", default=NULL,
              help="timepoint for the scenario (mandatory)", metavar="character"),
  make_option(c("-e", "--study_area_lcp"), type="character", default=NULL,
              help="path for study area tif file to which all the FOA rasters should snap", metavar="character"),
  make_option(c("-f", "--foa_seasons_csv"), type="character", default=NULL,
              help="CSV with FOA names and number of seasons", metavar="character")
)

# Parse the command-line options
opt_parser = OptionParser(option_list=option_list)
opt = parse_args(opt_parser)

# Set the working directory
setwd(opt$working_directory)
wd <- getwd()

# Create a directory to hold the results
merged_dir <- paste0("./okawen_", opt$run_timepoint, "_", opt$scenario, "_merged_outputs")
dir.create(merged_dir, showWarnings = FALSE)

# Read the study area raster and extract CRS, origin, and extent
study_area <- rast(opt$study_area_lcp)
study_area_crs <- crs(study_area)
study_area_origin <- origin(study_area)
study_area_extent <- ext(study_area)

# Read in the foa weights for weighted averaging
if (is.null(opt$foa_seasons_csv)) {
  stop("You must provide a CSV with FOA season weights via --foa_seasons_csv")
}

foa_weights <- read_csv(opt$foa_seasons_csv) %>%
  mutate(
    foa = as.character(foa),
    n_seasons = as.numeric(n_seasons)
  )

# Helper function to match directories to the foa names in the csv
get_foa_weight <- function(dir, foa_weights) {
  foa_match <- foa_weights %>%
    filter(str_detect(dir, fixed(foa)))
  if (nrow(foa_match) != 1) {
    stop(paste("Could not uniquely match FOA for directory:", dir))
  }
  foa_match$n_seasons
}

#Make a scenario_timepoint label to grep the correct run directories
run_label <- paste0(opt$scenario, "_", opt$run_timepoint)

# Locate subdirectories containing the scenario in their names
target_dirs <- list.dirs(path = wd, recursive = FALSE, full.names = TRUE) %>%
  .[grepl(run_label, .)]
if (length(target_dirs) == 0) {
  stop("No matching directories found for the specified scenario.")
}
message(paste0("Target directories for merging: ", target_dirs))

# Patterns to match each burn probability raster
patterns <- c(
  ".*FullRun_bp\\.tif$",
  ".*FullRun_cflp_0to2\\.tif$",
  ".*FullRun_cflp_2to4\\.tif$",
  ".*FullRun_cflp_4to6\\.tif$",
  ".*FullRun_cflp_6to8\\.tif$",
  ".*FullRun_cflp_8to12\\.tif$",
  ".*FullRun_cflp_12plus\\.tif$"
)

# Process each pattern
for (pattern in patterns) {
  message(paste0("Processing pattern:", pattern))
  
  # Collect all rasters matching the pattern from the target directories
  matched_files <- unlist(lapply(target_dirs, function(dir) {
    list.files(path = dir, pattern = pattern, full.names = TRUE)
  }))
  if (length(matched_files) == 0) {
    message(paste("No rasters found for pattern:", pattern))
    next
  }
  if(pattern == ".*FullRun_bp\\.tif$"){
    # Load and process the rasters
    processed_rasters <- lapply(matched_files, function(file) {
      r <- rast(file)
      # Match CRS, origin, and extent to the study area
      crs(r) <- study_area_crs
      origin(r) <- study_area_origin
      r <- terra::extend(r, study_area_extent)
      return(r)
    })
    # Merge the processed rasters
    stacked <- rast(processed_rasters)
    merged_raster <- terra::app(stacked, sum, na.rm = TRUE)
    # Define the output filename
    output_filename <- paste0(
      merged_dir, "/okawen_", opt$run_timepoint, "_", opt$scenario, "_", 
      sub(".*FullRun_", "FullRun_", sub("\\\\.tif\\$", "", pattern)), "_merged.tif"
    )
    # Save the merged raster
    writeRaster(merged_raster, output_filename, overwrite = TRUE)
    message(paste("Merged raster saved to:", output_filename))
  } else {  # Separate process for the CFLP rasters (BP-conditioned)
    # Load, align, and weight CFLP rasters by BP × seasons
    weighted_cflp <- lapply(matched_files, function(file) {
    # CFLP raster
    cflp <- rast(file)
    # Corresponding BP raster
    bp_file <- sub("_cflp_[^/]+\\.tif$", "_bp.tif", file)
    if (!file.exists(bp_file)) {
      stop(paste("Missing BP raster for:", file))
    }
    bp <- rast(bp_file)
    # Match CRS, origin, extent
    crs(cflp) <- study_area_crs
    origin(cflp) <- study_area_origin
    cflp <- terra::extend(cflp, study_area_extent)
    crs(bp) <- study_area_crs
    origin(bp) <- study_area_origin
    bp <- terra::extend(bp, study_area_extent)
    # Mask the CFLP raster wherever the BP is NA
    cflp <- terra::mask(cflp, bp)
    # FOA weight
    this_dir <- dirname(file)
    n_seasons <- get_foa_weight(this_dir, foa_weights)
    # Numerator contribution
    cflp * bp * n_seasons
  })
  # Denominator: BP × seasons
  weighted_bp <- lapply(matched_files, function(file) {
    bp_file <- sub("_cflp_[^/]+\\.tif$", "_bp.tif", file)
    bp <- rast(bp_file)
    crs(bp) <- study_area_crs
    origin(bp) <- study_area_origin
    bp <- terra::extend(bp, study_area_extent)
    n_seasons <- get_foa_weight(dirname(file), foa_weights)
    bp * n_seasons
  })
  # Sum numerator
  cflp_sum <- terra::app(rast(weighted_cflp), sum, na.rm = TRUE)
  bp_sum   <- terra::app(rast(weighted_bp), sum, na.rm = TRUE)
  # Final conditional CFLP
  merged_raster <- cflp_sum / bp_sum
  # Output filename
  output_filename <- paste0(
    merged_dir, "/okawen_", opt$run_timepoint, "_", opt$scenario, "_",
    sub(".*FullRun_", "FullRun_", sub("\\\\.tif\\$", "", pattern)), "_merged.tif"
  )
  writeRaster(merged_raster, output_filename, overwrite = TRUE)
  message(paste("BP-weighted CFLP raster saved to:", output_filename))
}}
