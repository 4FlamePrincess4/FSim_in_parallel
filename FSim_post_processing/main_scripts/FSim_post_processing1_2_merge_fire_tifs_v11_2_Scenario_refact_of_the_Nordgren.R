library(tidyverse)
library(sf)
library(terra)
library(tidyterra)
library(RSQLite)
library(future)
library(furrr)
library(optparse)

#Set up input arguments with optparse
option_list = list(
  make_option(c("-i", "--foa_lcp_path"), type="character", default=NULL,
              help="foa lcp path (mandatory)", metavar="character"),
  make_option(c("-w", "--working_directory"), type="character", default=NULL,
              help="working directory (mandatory)", metavar="character"),
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
  make_option(c("-o", "--output"), type="character", default="merge_tifs_captains_log.txt",
              help="output file [default= %default]", metavar="character"),
  make_option(c("-f", "--first_season"), type="integer", default=NULL,
              help="first season (mandatory)", metavar="integer"),
  make_option(c("-l", "--last_season"), type="integer", default=NULL,
              help="last season (mandatory)", metavar="integer"),
  make_option(c("-j", "--seasons_per_part"), type="character", default=NULL,
              help="vector of number of seasons in a part", metavar="character"),
  make_option(c("-m", "--merge_fires_part"), type="character", default=NULL,
              help="the part number for the merge fires script", metavar="character")
)
# parse the command-line options
opt_parser = OptionParser(option_list=option_list)
opt = parse_args(opt_parser)

#Set the working directory to the specific outputs folder for the run
setwd(opt$working_directory)
wd <- getwd()

#########################################################################################
# NOTE: To run this code, you need to make sure the following FSim outputs are in the   #
#       working directory: the FireSizeList.csv files, the  ArrivalDays tifs, the       #
#       FlameLengths tifs, the Ignitions.sqlite files, and the Perimeters.sqlite files. # 
#       You also need to use the rename_tifs script to append the directory name (with  #
#       the run & part info) to the beginning of the file names.                        #
#########################################################################################
##                                CODE DESCRIPTION                                     ##
# The plan is to use the fire perimeters to determine whether any fires overlap.        #
# If they do not overlap, we will simply merge the tifs. If they do overlap, we will    #
# store the fire IDs, use the IDs to fetch and stackthe correct tifs, do the            #
# cell-by-cell minimum arrival day operation to save only the earliest arrival days.    #
# We can then use the perimeters and ignition points to delete remaining overburn       #
# before moving on to the next season.                                                  #
######################################################################################### 

#STEP 1: Run information - see the slurm script
###############################################
# calculate or parse seasons_per_part
if (is.null(opt$seasons_per_part)) {
  seasons_per_part <- rep(opt$seasons_in_part, opt$number_of_parts)
} else {
  seasons_per_part <- as.integer(unlist(strsplit(opt$seasons_per_part, ",")))
}

#STEP 2: Combine fire lists from all four run parts
###############################################
#Read in run fire lists
firelist_files <- list.files(path=wd,
                             recursive=F,
                             pattern=".+FireSizeList.csv$",
                             full.names=T)
firelist_tables <- lapply(firelist_files, read.csv, header=TRUE)
#Combine the fire lists from all of the parts
firelists <- do.call(rbind, firelist_tables)
#Add a Season_FireID variable to distinguish fires with the same numbers but from different parts
firelists <- firelists %>%
  mutate(Season_FireID = paste0(Season,"_",FireID))

### Solution to create part labels for parts of varying numbers of seasons: ###

## First, make x number of vectors, where x is equal to the number of parts, 
## with a unique sequence of numbers corresponding to the seasons for each part.

#Grab the cumulative number of seasons per part
cumsum_seasons <- cumsum(seasons_per_part)
#remove the object "part_seasons" so that the ifelse statement in lines 56 through 61 works
remove(part_seasons)
part_seasons_list <- list()
for(j in 1:length(seasons_per_part)){
  if(exists("part_seasons")){
    part_seasons <- c((1+max(part_seasons)):(cumsum_seasons[j]))    
  }else{
    part_seasons <- c(1:seasons_per_part[j])
  }
  part_seasons_li <- list(assign(paste0("pt",j,"_seasons_",min(part_seasons),"_",max(part_seasons)), part_seasons))
  part_seasons_list <- append(part_seasons_list,part_seasons_li)
}

## Second, compare each fire's season to a list of seasons for each part and assign the 
## correct part label.

#Initialize an empty vector and add it as a column to the firelists dataframe
Part <- vector("character",nrow(firelists))
Scenario <- rep(opt$scenario, nrow(firelists))
Timepoint <- rep(opt$run_timepoint, nrow(firelists))
firelists <- cbind(firelists,Part,Scenario,Timepoint)
#Sort the firelists dataframe by Season number
firelists <- firelists[order(firelists$Season),]
#For each fire in the firelists dataframe
for(fire_record in 1:nrow(firelists)){
  #And for each part in the list of part vectors (with Season number sequences)
  for(part_seasons_li in seq_along(part_seasons_list)){
    #Make the list item a vector again
    this_vec <- unlist(part_seasons_list[part_seasons_li])
    #Compare each fire Season number to the vector of seasons corresponding to the part
    # and, if the fire Season number is in the vector, add the part label to the Part column
    if(firelists$Season[fire_record] %in% this_vec){
      firelists$Part[fire_record] <- paste0(sprintf("pt%s",part_seasons_li))
    }
  }
}

#STEP 3: Define a set of helper functions 
###############################################
#Function to start logging
start_logging <- function(log_file) {
  sink(log_file, append = TRUE, split = TRUE)
}

#Function to stop logging
stop_logging <- function() {
  sink()
}

#Create a function to count non-NA values that can be applied to each pixel in a raster stack
count_non_na <- function(x){
  num_non_na <- sum(!is.na(x))
  return(num_non_na)
}

#Create a function to find overlapping fire IDs
find_overlap_fireIDs <- function(overlap_matrix, fire_ids) {
  overlap_pairs <- list()
  n <- nrow(overlap_matrix)

  for (i in 1:(n - 1)) {
    for (j in (i + 1):n) {
      if (overlap_matrix[i, j]) {
        overlap_pairs <- append(
          overlap_pairs,
          list(c(fire_ids[i], fire_ids[j]))
        )
      }
    }
  }
  overlap_pairs
}

#Function to keep only minimum ArrivalDay values with Bryce's accumulator method
merge_tifs_w_accumulator <- function(arrival_day_path, flame_length_path, fire_id, foa_lcp, accum_AD, accum_FL, accum_ID) {
  
  # Read the ArrivalDay and FlameLength rasters
  arrival_day <- terra::rast(arrival_day_path)
  flame_length <- terra::rast(flame_length_path)
  # Set CRS to match foa_lcp
  terra::crs(arrival_day) <- terra::crs(foa_lcp)
  terra::crs(flame_length) <- terra::crs(foa_lcp)
  # Extend rasters to match the extent of foa_lcp
  arrival_day <- terra::extend(arrival_day, terra::ext(foa_lcp), snap="near")
  flame_length <- terra::extend(flame_length, terra::ext(foa_lcp), snap="near")
  
  # Compare ArrivalDay values with the accumulation raster
  mask_min <- arrival_day < accum_AD | is.na(accum_AD)
  
  # Update the accumulation raster with minimum values
  accum_AD[mask_min] <- arrival_day[mask_min]
  #terra::plot(accum_AD, main = "Accumulated arrival days")
  
  # Set non-minimum values to NA in the current fire's ArrivalDay raster
  arrival_day[!mask_min] <- NA
  
  # Use the adjusted ArrivalDay raster to mask the FlameLength raster
  flame_length_masked <- terra::mask(flame_length, arrival_day, maskvalue = NA)
  
  # Update the accumulation FlameLength raster
  accum_FL[!is.na(flame_length_masked)] <- flame_length_masked[!is.na(flame_length_masked)]
  #terra::plot(accum_FL, main = "Accumulated flame lengths")
  
  # Update the Fire ID raster with the current fire ID for minimum values
  accum_ID_mask <- !is.na(arrival_day)
  accum_ID[accum_ID_mask] <- as.numeric(fire_id)
  #terra::plot(accum_ID, main = "Accumulated fire IDs")
  
  return(list(accum_ID = accum_ID, accum_AD = accum_AD, accum_FL = accum_FL))
}

#STEP 4: Define smaller functions to be used within the larger process_fire_season function, which is then run with future_map()
########################################################################################################################
# NOTE: Before you can run this code, you need to give the fire tif files unique names indicating their run and part.  #
#   To do this, run the PowerShell script "rename_tifs.ps1", which you can download from the FSim_scripts Google Drive #
#   folder. You need to place the script in the folder, then you can right click and select the option to run the      #
#   script in PowerShell. The script will be renamed as well, but this doesn't matter. I suggest copying the original  #
#   to each folder and running the script before moving on to pasting into the next folder. The script is a small file.#
########################################################################################################################

#Define a function to process a season with just one fire.
process_single_fire_season <- function(each_season, this_season_fireIDs, this_season_foa_run, this_season_pt, this_season_scen, this_season_time) {
  print(paste0("There is only one fire in season ", each_season))
  #Read in FOA lcp as a template raster
  foa_lcp <- terra::rast(opt$foa_lcp_path, lyrs = 1)
  foa_lcp <- terra::unwrap(foa_lcp)
  #Read in the AD and FL rasters
  this_season_AD_filename <- paste0(wd,"/",this_season_foa_run, "_", this_season_pt,"_", this_season_scen, "_", this_season_time,"_ArrivalDays/",
                                     "FireID_", this_season_fireIDs, ".tif")
  this_season_AD_stack <- terra::rast(this_season_AD_filename)
  #Use this info to read in the flame length tif filenames for this season's fires
  this_season_FL_filename <- paste0(wd,"/",this_season_foa_run,"_",this_season_pt,"_", this_season_scen,"_",this_season_time,"_FlameLengths/",
                                     "FireID_", this_season_fireIDs, ".tif")
  this_season_FL_stack <- terra::rast(this_season_FL_filename)
  # Set CRS to match foa_lcp
  terra::crs(this_season_AD_stack) <- terra::crs(foa_lcp)
  terra::crs(this_season_FL_stack) <- terra::crs(foa_lcp)
  # Extend rasters to match the extent of foa_lcp
  this_season_AD_stack <- terra::extend(this_season_AD_stack, terra::ext(foa_lcp), snap="near")
  this_season_FL_stack <- terra::extend(this_season_FL_stack, terra::ext(foa_lcp), snap="near")
  # Convert flame lengths from meters to feet
  this_season_FL_stack <- this_season_FL_stack * 3.28084
  #Create the fire ID raster
  this_season_ID_stack <- terra::rast(nrows = nrow(this_season_AD_stack), ncols = ncol(this_season_AD_stack), ext = terra::ext(this_season_AD_stack), crs = terra::crs(this_season_AD_stack), vals = NA)
  this_season_fireIDs <- as.numeric(this_season_fireIDs)
  for(fireid in 1:terra::nlyr(this_season_AD_stack)){
    this_fireid <- this_season_fireIDs[fireid]
    this_AD_raster <- this_season_AD_stack[[fireid]]
    mask <- !is.na(this_AD_raster)
    this_season_ID_stack[mask] <- this_fireid
  }
  #Combine the fire ID stack with the AD & FL stacks. (Each "stack" actually only has one layer because there is only one fire.)
  season_fires_raster_stack <- c(this_season_ID_stack, this_season_AD_stack, this_season_FL_stack)
  names(season_fires_raster_stack) <- c("Fire_IDs", "Julian_Arrival_Days", "Flame_Lengths_ft")
  #plot(season_fires_raster_stack, main = paste0("Season ", each_season))
  #Write the resulting 3-band raster stack.
  terra::writeRaster(season_fires_raster_stack, filename=paste0("./SeasonFires_merged_tifs_", opt$scenario, "_", opt$run_timepoint, "/Season", each_season,"_merged_IDs_ADs_FLs.tif"), overwrite = TRUE)
  rm(this_season_AD_stack, this_season_FL_stack, this_season_ID_stack, season_fires_raster_stack, foa_lcp)
  gc()
}

process_overlaps <- function(each_season, this_season_fireIDs, this_season_foa_run, this_season_pt, this_season_scen, this_season_time, season_fire_perims, ref_sys, overlap_fireIDs){
  library(RSQLite)
  fires_to_delete <- character()
  overlapping_fire_ids_df <- do.call(
   rbind,
   lapply(overlap_fireIDs, function(pair) {
     data.frame(
       fire_id1 = pair[1],
       fire_id2 = pair[2],
       stringsAsFactors = FALSE
     )
   })
  )
  #Read in ignitions for the overlapping fire ids
  #We only need the unique ids for this
  unique_overlapping_fire_ids <- c(overlapping_fire_ids_df$fire_id1, 
                                   overlapping_fire_ids_df$fire_id2)
  unique_overlapping_fire_ids <- unique(unique_overlapping_fire_ids)
  # Load the ignition database corresponding to the season part
  con <- RSQLite::dbConnect(RSQLite::SQLite(), dbname = paste0(wd,"/", opt$foa_run, "_", this_season_pt[1], 
                                                               "_", opt$scenario,"_", opt$run_timepoint, "_Ignitions.sqlite"))
  # Construct the SQL query to select the ignitions based on the IDs
  query <- paste("SELECT * FROM ignitions WHERE fire_id IN (", 
                 toString(unique_overlapping_fire_ids),")")
  # Query the sqlite database to fetch only the ignitions that are in the overlapping id list
  overlapping_ig <- RSQLite::dbGetQuery(con, query)
  #Get the reference system (which is the same for all three)
  ref_sys <- RSQLite::dbGetQuery(con, "SELECT * FROM spatial_ref_sys")
  # Close the database connection
  RSQLite::dbDisconnect(con)
  # Convert the geometry column to sf objects
  colnames(overlapping_ig)[colnames(overlapping_ig) == "ignition_x"]<- "lon"
  colnames(overlapping_ig)[colnames(overlapping_ig) == "ignition_y"]<- "lat"
  overlapping_ig <- terra::vect(x = overlapping_ig, crs=ref_sys$srtext)
  overlapping_ig <- tidyterra::as_sf(overlapping_ig)
  
  #Check for cases where the ignitions fall into the corresponding polygons.
  # Iterate over each pair of overlapping fires.
  for(pairs in 1:nrow(overlapping_fire_ids_df)){
    # Grab each ID
    first_ID <- overlapping_fire_ids_df$fire_id1[pairs]
    second_ID <- overlapping_fire_ids_df$fire_id2[pairs]
    # Subset the season polygons and the overlapping fire ignitions with these IDs
    first_ig <- overlapping_ig %>%
      dplyr::filter(fire_id == first_ID)
    second_ig <- overlapping_ig %>%
      dplyr::filter(fire_id == second_ID)
    first_perim <- season_fire_perims %>%
      dplyr::filter(fire_id == first_ID)
    second_perim <- season_fire_perims %>%
      dplyr::filter(fire_id == second_ID)
    # # Plot these as a sanity check
    # overlap_case_plot <- ggplot2::ggplot()+
    #   ggplot2::geom_sf(data=first_perim, aes(color = "Fire 1 Perim"))+
    #   ggplot2::geom_sf(data=first_ig, aes(color = "Fire 1 Ig"))+
    #   ggplot2::geom_sf(data=second_perim, aes(color = "Fire 2 Perim"))+
    #   ggplot2::geom_sf(data=second_ig, aes(color = "Fire 2 Ig"))+
    #   ggplot2::scale_color_manual(values=c("Fire 1 Perim" = "black","Fire 1 Ig" = "red",
    #                               "Fire 2 Perim" = "blue","Fire 2 Ig" = "green"))+
    #   ggplot2::theme_minimal()
    # print(overlap_case_plot)
    
    # Check whether the first ignition falls in the second perimeter
    first_ignition_in_second_perim <- sf::st_intersects(first_ig, second_perim, sparse = FALSE)
    # Check whether the second ignition falls in the first perimeter
    second_ignition_in_first_perim <- sf::st_intersects(second_ig, first_perim, sparse = FALSE)
    #If the first ignition is inside the second perimeter
    if(first_ignition_in_second_perim){
      #Check whether the ignition day is earlier than the arrival day at the pixel of the perimeter
      # Extract the coordinates of the ignition point
      first_ig_coords <- sf::st_coordinates(first_ig)
      # Extract the arrival day value at the ignition point location
      this_perim_AD_raster <- terra::rast(paste0(wd, "/", this_season_foa_run, "_", this_season_pt, "_", this_season_scen,"_",this_season_time, "_ArrivalDays/",
                                                 "FireID_", second_ID, ".tif"))
      second_fire_AD_value <- terra::extract(this_perim_AD_raster, sf::st_coordinates(first_ig))[1, 1]
      print(paste0("The arrival day for fire ", second_ID, " is ", second_fire_AD_value, "."))
      # Compare the start_day with the arrival_day_value
      if (!is.na(second_fire_AD_value)) {
        if (first_ig$start_day <= second_fire_AD_value) {
          print(paste0("The ignition date for fire ", first_ID, " is ", first_ig$start_day, ", which is less than or equal to the arrival day value for fire ", second_ID, " at the ignition point's location."))
          print("We will keep both fires.")
        } else { #End of if-else scenario where the first fire ignition is within the second fire perim
          # & the first fire would have prevented the second fire from spreading. #End of if-else scenario where the ignition date of fire 1 is less than or equal to the AD of fire 2.
          print(paste0("The ignition date for fire ", first_ID, " is ", first_ig$start_day, ", which is greater than the arrival day value for fire ", second_ID, " at the ignition point's location."))
          print(paste0("Fire ", first_ID, " should not have occurred and will be deleted."))
          #Store the ID in a list to delete the FL and AD rasters from the stacks just before merging.
          fires_to_delete <- union(fires_to_delete, first_ID)
        } #End of if-else scenario where the ignition for fire 1 is inside of the fire 2 perimeter and
        # fire 1 should not have ignited.
      } else { #End of scenario where the second fire AD value is not NA.
        print("No valid arrival_day value at the ignition point's location.")
        print(paste0("Ignition fire ID = ", first_ID, ". Perimeter fire ID = ", second_ID, ". The ignition point location is ", first_ig_coords, "."))
      } #End of scenario where the second fire AD value is NA.
    } else if(second_ignition_in_first_perim){ #End of if-else scenario where the first fire ignition is inside of the second fire perimeter.
      #Check whether the ignition day is earlier than the arrival day at the pixel of the perimeter
      # Extract the coordinates of the ignition point
      second_ig_coords <- sf::st_coordinates(second_ig)
      # Extract the arrival day value at the ignition point location
      this_perim_AD_raster <- terra::rast(paste0(wd, "/", this_season_foa_run, "_", this_season_pt, "_", this_season_scen,"_",this_season_time, "_ArrivalDays/",
                                                 "FireID_", first_ID, ".tif"))
      first_fire_AD_value <- terra::extract(this_perim_AD_raster, sf::st_coordinates(second_ig))[1, 1]
      print(paste0("The arrival day for fire ", first_ID, " is ", first_fire_AD_value, "."))
      # Compare the start_day with the arrival_day_value
      if (!is.na(first_fire_AD_value)) {
        if (second_ig$start_day <= first_fire_AD_value) {
          print(paste0("The ignition date for fire ", second_ID, " is ", second_ig$start_day, " which is less than or equal to the arrival day value for fire ", first_ID, " at the ignition point's location."))
          print("We will keep both fires.")
        } else { #End of if-else scenario where the fire 2 ignition is within the fire 1 perim
          # & fire 2 would have prevented fire 1 from spreading.
          #End of if-else scenario where the fire 2 ignition is earlier than the fire 1 AD value.
          print(paste0("The ignition date for fire ", second_ID, " is greater than the arrival day value for fire ", first_ID, " at the ignition point's location."))
          print(paste0("Fire ", second_ID, " should not have occurred and will be deleted."))
          #Store the ID in a list to delete the FL and AD rasters from the stacks just before merging.
          fires_to_delete <- union(fires_to_delete, second_ID)
        } #End of if-else scenario where the ignition for fire 1 is inside of the fire 2 perimeter and the
        # ignition date is later than the fire 2 arrival day, so fire 1 would not have occurred.
      } else {#End of scenario where the AD value at the ignition point is not NA.
        print(paste0("No valid arrival_day value at the ignition point's location. The coordinates for fire ", second_ID, " are: ", second_ig_coords, "."))
        print(paste0("Ignition fire ID = ", second_ID, ". Perimeter fire ID = ", first_ID, "."))
      } #End of if-else scenario where the AD value at the ignition point is NA.
    } else if(!(first_ignition_in_second_perim) && !(second_ignition_in_first_perim)){ #End of scenario where fire 2 ignition is inside of fire 1 perimeter.
      #If the ignitions don't fall into the other polygons,
      # subtract the polygon of the ignition point of fire 1 from the polygon of the later fire (fire 2)
      print("The ignitions don't fall into the perimeters of the overlapping fires.")
      print("We are assuming that keeping only the earliest arrival day value will take care of overburn.")
    } #End of the if-else situation where the ignitions don't overlap with the polygons of overlapping fires.
  } #End of the for loop to edit each pair of fires that overlap.
  
  #Delete the arrival day and flame length tifs of fires that shouldn't have happened
  if(length(fires_to_delete) > 0){
    this_season_fireIDs <- setdiff(this_season_fireIDs, fires_to_delete)
  }
  # Create empty accumulator rasters
  foa_lcp <- terra::rast(opt$foa_lcp_path, lyrs = 1)
  foa_lcp <- terra::unwrap(foa_lcp)
  accum_ID <- terra::rast(foa_lcp)
  accum_AD <- terra::rast(foa_lcp)
  accum_FL <- terra::rast(foa_lcp)
  # Initialize accumulator rasters with NAs
  terra::values(accum_ID) <- NA
  terra::values(accum_AD) <- NA
  terra::values(accum_FL) <- NA
  # Create lists of the file names for the season
  this_season_AD_filenames <- paste0(wd,"/",this_season_foa_run,"_",this_season_pt, "_", this_season_scen,"_",this_season_time, "_ArrivalDays/",
                                     "FireID_", this_season_fireIDs, ".tif")
  this_season_FL_filenames <- paste0(wd,"/",this_season_foa_run,"_",this_season_pt, "_", this_season_scen,"_",this_season_time, "_FlameLengths/",
                                     "FireID_", this_season_fireIDs, ".tif")
  # Read in each fire and update the accumulators
  for(fire in 1:length(this_season_AD_filenames)){
        # Check if both .tif files exist
        if (!file.exists(this_season_AD_filenames[fire]) || !file.exists(this_season_FL_filenames[fire])) {
          cat(sprintf("File does not exist for FireID %s: %s or %s\n",
                this_season_fireIDs[fire],
                this_season_AD_filenames[fire],
                this_season_FL_filenames[fire]))
          next  # Skip to the next iteration if either file is missing
        }
        # If files exist, proceed to merge
        result <- merge_tifs_w_accumulator(this_season_AD_filenames[fire], this_season_FL_filenames[fire],
                                           this_season_fireIDs[fire], foa_lcp, accum_AD, accum_FL, accum_ID)
        accum_ID <- result$accum_ID
        accum_AD <- result$accum_AD
        accum_FL <- result$accum_FL
      }
  # Convert flame lengths from meters to feet
  accum_FL <- accum_FL * 3.28084
  season_fires_raster_stack <- c(accum_ID, accum_AD, accum_FL)
  names(season_fires_raster_stack) <- c("Fire_IDs", "Julian_Arrival_Days", "Flame_Lengths_ft")
  #plot(season_fires_raster_stack, main = paste0("Season ", each_season))
  #Write the resulting 3-band raster stack.
  terra::writeRaster(season_fires_raster_stack, filename=paste0("./SeasonFires_merged_tifs_", opt$scenario, "_", opt$run_timepoint,"/Season", each_season,"_merged_IDs_ADs_FLs.tif"), overwrite = TRUE)
  rm(accum_AD, accum_FL, accum_ID, season_fires_raster_stack, foa_lcp)
  gc()
}

process_fire_season <- function(each_season) {
  library(RSQLite)
  print(paste0("Processing Season ", each_season,"..."))
  foa_lcp <- terra::rast(opt$foa_lcp_path, lyrs = 1)
  foa_lcp <- terra::unwrap(foa_lcp)
  #Subset the firelists by the current season
  this_season_fires <- firelists %>%
    dplyr::filter(Season == each_season)
  # Check if the dataframe is empty
  if (nrow(this_season_fires) == 0) {
    print(paste0("Season ", each_season, " had 0 fires. An empty placeholder raster will be saved."))
    # Create an empty raster
    foa_lcp <- terra::rast(opt$foa_lcp_path, lyrs = 1)
    foa_lcp <- terra::unwrap(foa_lcp)
    no_fires_ID <- terra::rast(foa_lcp)
    no_fires_AD <- terra::rast(foa_lcp)
    no_fires_FL <- terra::rast(foa_lcp)
    terra::values(no_fires_ID) <- NA
    terra::values(no_fires_AD) <- NA
    terra::values(no_fires_FL) <- NA
    season_fires_raster_stack <- c(no_fires_ID, no_fires_AD, no_fires_FL)
    names(season_fires_raster_stack) <- c("Fire_IDs", "Julian_Arrival_Days", "Flame_Lengths_ft")
    # Save the empty raster
    terra::writeRaster(season_fires_raster_stack, filename = paste0("./SeasonFires_merged_tifs_", opt$scenario,"_", opt$run_timepoint, "/Season", each_season,"_merged_IDs_ADs_FLs.tif"), overwrite = TRUE)
    rm(no_fires_ID, no_fires_AD, no_fires_FL, season_fires_raster_stack, foa_lcp)
    gc()
    # Exit the function
    return(invisible(NULL))
  }
  #Fetch vectors of other run information
  this_season_fires <- this_season_fires |>
        dplyr::arrange(FireID)
  this_season_fireIDs <- as.character(this_season_fires$FireID)
  this_season_pt <- as.character(rep(this_season_fires$Part[1], length(this_season_fireIDs)))
  this_season_scen <- rep(opt$scenario, length(this_season_fireIDs))
  this_season_time <- rep(opt$run_timepoint, length(this_season_fireIDs))
  this_season_foa_run <- rep(opt$foa_run, length(this_season_fireIDs))
  #If there is one or fewer fires in the season, use the process_single_fire_season function 
  if(length(this_season_fireIDs) == 1){
    #Determine whether any of the fires have an area burned of 0 acres.
    #These should be removed because they will not contribute to overburn, 
    # and they will cause errors in the event of a record: off run where a previously run fire does not burn.
    this_season_fires_no_area <- this_season_fires %>% 
      dplyr::filter(Acres == 0)
    if(nrow(this_season_fires_no_area) > 0){
      print(paste0("Season ", each_season, " fire ", this_season_fires_no_area$FireID,
                 " has a burned area of 0 acres."))
      print("These fires will not be assessed for overburn.")
    }
    this_season_fires <- this_season_fires %>%
      dplyr::filter(Acres > 0)
    if(nrow(this_season_fires) == 0){
      print(paste0("Season ", each_season, " had 0 fires after filtering out fires with no burned area. An empty placeholder raster will be saved."))
      # Create empty raster
      foa_lcp <- terra::rast(opt$foa_lcp_path, lyrs = 1)
      foa_lcp <- terra::unwrap(foa_lcp)
      no_fires_ID <- terra::rast(foa_lcp)
      no_fires_AD <- terra::rast(foa_lcp)
      no_fires_FL <- terra::rast(foa_lcp)
      terra::values(no_fires_ID) <- NA
      terra::values(no_fires_AD) <- NA
      terra::values(no_fires_FL) <- NA
      season_fires_raster_stack <- c(no_fires_ID, no_fires_AD, no_fires_FL)
      names(season_fires_raster_stack) <- c("Fire_IDs", "Julian_Arrival_Days", "Flame_Lengths_ft")
      # Save the empty raster (optional, based on your workflow)
      terra::writeRaster(season_fires_raster_stack, filename = paste0("./SeasonFires_merged_tifs_", opt$scenario,"_", opt$run_timepoint, "/Season", each_season,"_merged_IDs_ADs_FLs.tif"), overwrite = TRUE)
      rm(no_fires_ID, no_fires_AD, no_fires_FL, season_fires_raster_stack, foa_lcp)
      gc()
      # Exit the function
      return(invisible(NULL))
    }
    #Fetch vectors of other run information
    this_season_fires <- this_season_fires |>
        dplyr::arrange(FireID)
    this_season_fireIDs <- as.character(this_season_fires$FireID)
    this_season_pt <- as.character(rep(this_season_fires$Part[1], length(this_season_fireIDs)))
    this_season_scen <- rep(opt$scenario, length(this_season_fireIDs))
    this_season_time <- rep(opt$run_timepoint, length(this_season_fireIDs))
    this_season_foa_run <- rep(opt$foa_run, length(this_season_fireIDs))
    process_single_fire_season(each_season, this_season_fireIDs, this_season_foa_run, this_season_pt,this_season_scen,this_season_time)
  } 
  if(length(this_season_fireIDs) >=2){ #Otherwise, read in the perimeters sqlite database and fetch this season's fire perimeters
    #Check for cases where, after filtering out fires with no burned area, there was only one fire left in the season.
    #Determine whether any of the fires have an area burned of 0 acres.
    #These should be removed because they will not contribute to overburn, 
    # and they will cause errors in the event of a record: off run where a previously run fire does not burn.
    this_season_fires_no_area <- this_season_fires %>% 
      dplyr::filter(Acres == 0)
    if(nrow(this_season_fires_no_area) > 0){
      print(paste0("Season ", each_season, " fire ", this_season_fires_no_area$FireID,
                 " has a burned area of 0 acres."))
      print("These fires will not be assessed for overburn.")
    }
    this_season_fires <- this_season_fires %>%
      dplyr::filter(Acres > 0)
    if(nrow(this_season_fires) == 0){
      print(paste0("Season ", each_season, " had 0 fires after filtering out fires with no burned area. An empty placeholder raster will be saved."))
      # Create empty raster
      foa_lcp <- terra::rast(opt$foa_lcp_path, lyrs = 1)
      foa_lcp <- terra::unwrap(foa_lcp)
      no_fires_ID <- terra::rast(foa_lcp)
      no_fires_AD <- terra::rast(foa_lcp)
      no_fires_FL <- terra::rast(foa_lcp)
      terra::values(no_fires_ID) <- NA
      terra::values(no_fires_AD) <- NA
      terra::values(no_fires_FL) <- NA
      season_fires_raster_stack <- c(no_fires_ID, no_fires_AD, no_fires_FL)
      names(season_fires_raster_stack) <- c("Fire_IDs", "Julian_Arrival_Days", "Flame_Lengths_ft")
      # Save the empty raster (optional, based on your workflow)
      terra::writeRaster(season_fires_raster_stack, filename = paste0("./SeasonFires_merged_tifs_", opt$scenario,"_", opt$run_timepoint, "/Season", each_season,"_merged_IDs_ADs_FLs.tif"), overwrite = TRUE)
      rm(no_fires_ID, no_fires_AD, no_fires_FL, season_fires_raster_stack, foa_lcp)
      gc()
      # Exit the function
      return(invisible(NULL))
    }
    if(nrow(this_season_fires) == 1){
      #Check for cases where, after filtering out fires with no burned area, there was only one fire left in the season.
      #Fetch vectors of other run information
      this_season_fires <- this_season_fires |>
        dplyr::arrange(FireID)
      this_season_fireIDs <- as.character(this_season_fires$FireID)
      this_season_pt <- as.character(rep(this_season_fires$Part[1], length(this_season_fireIDs)))
      this_season_scen <- rep(opt$scenario, length(this_season_fireIDs))
      this_season_time <- rep(opt$run_timepoint, length(this_season_fireIDs))
     this_season_foa_run <- rep(opt$foa_run, length(this_season_fireIDs))
      process_single_fire_season(each_season, this_season_fireIDs, this_season_foa_run, this_season_pt,this_season_scen,this_season_time)
    } 
    if(nrow(this_season_fires) >=2) {
      #Check for cases where, after filtering out fires with no burned area, there are still 2 or more fires left in the season. Now you can check for overlap and delete overburn.
      #Fetch vectors of other run information
      this_season_fires <- this_season_fires |>
        dplyr::arrange(FireID)
      this_season_fireIDs <- as.character(this_season_fires$FireID)
      this_season_pt <- as.character(rep(this_season_fires$Part[1], length(this_season_fireIDs)))
      this_season_scen <- rep(opt$scenario, length(this_season_fireIDs))
      this_season_time <- rep(opt$run_timepoint, length(this_season_fireIDs))
      this_season_foa_run <- rep(opt$foa_run, length(this_season_fireIDs))
      con <- RSQLite::dbConnect(RSQLite::SQLite(), dbname = paste0(wd,"/", opt$foa_run, "_", this_season_pt[1], "_", opt$scenario,"_", opt$run_timepoint, "_Perimeters.sqlite"))
      query1 <- paste("SELECT * FROM perimeters WHERE fire_id IN (", toString(this_season_fireIDs),")")
      season_fire_perims <- RSQLite::dbGetQuery(con, query1)
      ref_sys <- RSQLite::dbGetQuery(con, "SELECT * FROM spatial_ref_sys")
      RSQLite::dbDisconnect(con)
      #Convert these perimeters to an sf object
      season_fire_perims$GEOMETRY <- sf::st_as_sfc(structure(as.list(season_fire_perims$GEOMETRY),class="blob"), crs = ref_sys$srtext)
      season_fire_perims <- sf::st_as_sf(season_fire_perims)
      season_fire_perims <- season_fire_perims |>
        dplyr::arrange(fire_id)
      this_season_fireIDs <- as.character(season_fire_perims$fire_id)
      #Check whether any of the fire perimeters for this season overlap. The result is a matrix of logical outcomes.
      overlap_matrix <- sf::st_intersects(season_fire_perims, sparse = FALSE)
      #Use the function find_overlap_fireIDs to determine which fires overlap with which other fires.
      overlap_fireIDs <- find_overlap_fireIDs(overlap_matrix, this_season_fireIDs)
      cat(sprintf("There are %d cases where fires overlap in season %s.\n", length(overlap_fireIDs), each_season))
      #If no fires overlap, use the merge_and_write_rasters function to export the 3-band season tif.
      if(length(overlap_fireIDs) == 0){
        # Create empty accumulator rasters
        accum_ID <- terra::rast(foa_lcp)
        accum_AD <- terra::rast(foa_lcp)
        accum_FL <- terra::rast(foa_lcp)
        # Initialize accumulator rasters with NAs
        terra::values(accum_ID) <- NA
        terra::values(accum_AD) <- NA
        terra::values(accum_FL) <- NA
        # Create lists of the file names for the season
        this_season_AD_filenames <- paste0(wd,"/",this_season_foa_run,"_",this_season_pt,"_", this_season_scen,"_",this_season_time,"_ArrivalDays/",
                                           "FireID_", this_season_fireIDs, ".tif")
        this_season_FL_filenames <- paste0(wd,"/",this_season_foa_run,"_",this_season_pt,"_", this_season_scen,"_",this_season_time,"_FlameLengths/",
                                           "FireID_", this_season_fireIDs, ".tif")
        # Read in each fire and update the accumulators
        for(fire in 1:length(this_season_AD_filenames)){
          # Check if both .tif files exist
          if (!file.exists(this_season_AD_filenames[fire]) || !file.exists(this_season_FL_filenames[fire])) {
            cat(sprintf("File does not exist for FireID %s: %s or %s\n",
                        this_season_fireIDs[fire],
                        this_season_AD_filenames[fire],
                        this_season_FL_filenames[fire]))
            next  # Skip to the next iteration if either file is missing
          }
          # If files exist, proceed to merge
          result <- merge_tifs_w_accumulator(this_season_AD_filenames[fire], this_season_FL_filenames[fire],
                                             this_season_fireIDs[fire], foa_lcp, accum_AD, accum_FL, accum_ID)
          accum_ID <- result$accum_ID
          accum_AD <- result$accum_AD
          accum_FL <- result$accum_FL
        }
        # Convert flame lengths from meters to feet
        accum_FL <- accum_FL * 3.28084
        season_fires_raster_stack <- c(accum_ID, accum_AD, accum_FL)
        names(season_fires_raster_stack) <- c("Fire_IDs", "Julian_Arrival_Days", "Flame_Lengths_ft")
        #plot(season_fires_raster_stack, main = paste0("Season ", each_season))
        #Write the resulting 3-band raster stack.
        terra::writeRaster(season_fires_raster_stack, filename=paste0("./SeasonFires_merged_tifs_", opt$scenario,"_", opt$run_timepoint, "/Season", each_season,"_merged_IDs_ADs_FLs.tif"), overwrite = TRUE)
        rm(accum_AD, accum_FL, accum_ID, season_fires_raster_stack, foa_lcp)
        gc()
      }else if(length(overlap_fireIDs) >= 1){ #If there's at least one case of overlap, use the function process_overlapping_fires.
        process_overlaps(each_season, this_season_fireIDs, this_season_foa_run, this_season_pt, this_season_scen, this_season_time, season_fire_perims, ref_sys, overlap_fireIDs)
        rm(foa_lcp)
        gc()
      }
    }
  } 
}

#STEP 5: Process seasons in parallel across multiple cores
#############################################################

# Define the processing function to be run in parallel
process_single_season <- function(each_season) {
  process_fire_season(each_season)
}

unique_seasons <- opt$first_season:opt$last_season
print(paste("Processing seasons:", paste(unique_seasons, collapse = ", ")))

# Set up logger
merge_log_filename <- paste0("merge_tifs_captains_log_", opt$merge_fires_part, ".txt")
start_logging(merge_log_filename)

#Use the below if you're on one of the Titan machines
#Set up a cluster and using that with future_map()
#cl <- parallel::makeCluster(32)
#plan(cluster, workers = cl)

#Use the below if you're on the Alderaan cluster
# Set up the future plan to use the cluster
plan(cluster, workers = 64)

# Increase serialization buffer size 
options(future.globals.maxSize = +Inf) #Just remove the check by setting it to infinity 

future_options <- furrr_options(globals=c("wd", "firelists", "opt",
                                          "merge_log_filename","process_single_season",
                                          "process_fire_season", "find_overlap_fireIDs",
                                          "process_overlapping_fires", 
                                          "handle_more_than_two_overlaps", "handle_two_or_fewer_overlaps", 
                                          "process_overlaps", "merge_tifs_w_accumulator", 
                                          "process_single_fire_season", "count_non_na"), seed=TRUE)

# Use future_map to process in parallel
results <- future_map(
  unique_seasons,
  ~{
    tryCatch({
      process_single_season(.x)
    }, error = function(e) {
      message <- paste("Error in season", .x, ":", e)
      cat(message, file = merge_log_filename, append = TRUE)
      return(NULL)
    })
  },
  .options = future_options
)

stop_logging()
