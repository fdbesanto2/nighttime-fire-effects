# Purpose: overpass correction for Aqua / Terra to account for more possible
# overpasses at higher latitudes.

library(tidyverse)
library(reticulate)
library(lubridate)
library(sf)
library(raster)
library(fasterize)
library(rnaturalearth)
library(viridis)
library(geosphere)
library(mgcv)

# function that creates bowtie polygon ------------------------------------

modis_bowtie_buffer <- function(obj, nadir = FALSE, bowtie = FALSE) {
  
  # 1.477 seconds per scan (Wolfe et al., 2002)
  # 10 km along-track distance in a single scan
  # 2340 km swath width
  # 1 / 1.477 [sec per scan] * 60 [sec per minute] * 10 [km along-track per scan] * 1000 [m per km]
  # Equals 406.22884 km along-track per minute
  
  dist_along_track_per_minute_m <- 1 / 1.477 * 60 * 10 * 1000
  swath_width_m <- 2330 * 1000
  
  # orbital inclination of 98.2 degrees (i.e., 8.2 degrees west of due north on ascending node)
  # not ready to say that this is a definitely usable piece of this footprint creation, so
  # keeping it to 0 for now (to make footprints always be oriented north/south). Perhaps
  # better to use the swath width along the predicted orbit path, but that has its own challenges
  orbit_incl_offset <- 0
  
  # full-width offset or nadir offset?
  # assume a much narrower swath width if just considering the pixels closest to nadir
  # here, I chose a 24-degree scan angle as still being nadir because this is
  # the widest angle at which there is no overlap with other scans
  
  x_offset <- ifelse(nadir, 
                     yes = ((swath_width_m / 2) / (tan(55 * pi / 180)) * tan(24 * pi / 180)),
                     no = swath_width_m / 2)
  
  y_offset_small <- dist_along_track_per_minute_m / 2
  
  # Very slight bowtie flaring because only one additional scan's bowtie
  # effect gets added to the cumulative track-length from one minute of the
  # satellite's movement
  # Option to turn off this flaring in the 'bowtie=' argument; default is to square off the 
  # footprint, rather than to bowtie.
  y_offset_large <- ifelse(nadir,
                           yes = y_offset_small,
                           no = ifelse(bowtie, 
                                       yes = (dist_along_track_per_minute_m / 2) + 10000,
                                       no = y_offset_small))
  
  # The bowtie is defined by 6 points relative to the footprint center. 
  # Even if the bowtie is squared off and is just a rectangle,
  # we still define 6 points.
  # pt1 is straight forward from the lon/lat in the along-track direction
  # pt2 is forward in the along track direction and right in the along scan direction
  # pt3 is behind in the along track direction and right in the along scan direction
  # pt4 is straight behind in the along track direction
  # pt5 is behind in the along track direction and left in the along scan direction
  # pt6 is forward in the along track direction and left in the along scan direction
  
  hypotenuse_dist <- sqrt(y_offset_large ^ 2 + x_offset ^ 2)
  corner_angles <- atan(y_offset_large / x_offset) * 180 / pi
  
  bowties <-
    obj %>% 
    st_drop_geometry() %>% 
    dplyr::select(lon, lat) %>% 
    purrr::pmap(.f = function(lon, lat) {
      
      pt1 <- geosphere::destPoint(p = c(lon, lat), b = 0 - orbit_incl_offset, d = y_offset_small)
      pt2 <- geosphere::destPoint(p = c(lon, lat), b = 90 - orbit_incl_offset - corner_angles, d = hypotenuse_dist)
      pt3 <- geosphere::destPoint(p = c(lon, lat), b = 90 - orbit_incl_offset + corner_angles, d = hypotenuse_dist)
      pt4 <- geosphere::destPoint(p = c(lon, lat), b = 180 - orbit_incl_offset, d = y_offset_small)
      pt5 <- geosphere::destPoint(p = c(lon, lat), b = 270 - orbit_incl_offset - corner_angles, d = hypotenuse_dist)
      pt6 <- geosphere::destPoint(p = c(lon, lat), b = 270 - orbit_incl_offset + corner_angles, d = hypotenuse_dist)
      
      n_pts <- 3
      
      bowtie <-
        rbind(
          pt1,
          geosphere::gcIntermediate(pt1, pt2, n = n_pts),
          pt2,
          geosphere::gcIntermediate(pt2, pt3, n = n_pts),
          pt3,
          geosphere::gcIntermediate(pt3, pt4, n = n_pts),
          pt4,
          geosphere::gcIntermediate(pt4, pt5, n = n_pts),
          pt5,
          geosphere::gcIntermediate(pt5, pt6, n = n_pts),
          pt6,
          geosphere::gcIntermediate(pt6, pt1, n = n_pts),
          pt1) %>% 
        list() %>% 
        st_polygon()
      
      return(bowtie)
    })
  
  new_obj <-
    obj %>%
    st_drop_geometry() %>% 
    dplyr::mutate(geometry = st_sfc(bowties, crs = st_crs(obj))) %>% 
    st_as_sf() %>% 
    st_wrap_dateline()
  
  return(new_obj)
}


# setup python pieces -----------------------------------------------------
# create a conda environment called "r-reticulate" if there isn't one already
# Include the pyorbital package in the install
reticulate::conda_install("r-reticulate", packages = "pyorbital", pip = TRUE, forge = TRUE, python_version = "3.7")
# conda_remove("r-reticulate")

# Activate the "r-reticulate" environment
reticulate::use_condaenv("r-reticulate")

# datetime <- reticulate::import("datetime")

if(Sys.info()['sysname'] == "Windows") {
  orb <- reticulate::import("pyorbital.orbital")
} else {
  orb <- reticulate::import("pyorbital")
  orb <- orb$orbital}


# get TLE files -----------------------------------------------------------
# The TLE comes in a single big text file, but only the single TLE for a particular
# time should be used for the orbital positioning. This requires breaking
# apart the giant table of TLEs into individual TLEs based on the date. This will
# also allow matching of the TLE dates to the nearest datetime when the orbit
# prediction is to be made. That is, if we want a predicted location of the
# Aqua satellite on 2017-04-12 at 0900, we want to use the TLE with a datetime
# closest to that day and time.

aqua_tle <- 
  read_fwf(file = "data/data_raw/aqua_27424_TLE_2002-06-01_2019-10-22.txt", fwf_widths(69)) %>% 
  dplyr::rename(line = X1) %>% 
  dplyr::mutate(line_number = as.numeric(substr(line, start = 1, stop = 1))) %>% 
  dplyr::mutate(id = rep(1:(n() / 2), each = 2),
                satellite = "aqua")

terra_tle <- 
  read_fwf(file = "data/data_raw/terra_25994_TLE_2002-06-01_2019-10-22.txt", fwf_widths(69)) %>% 
  dplyr::rename(line = X1) %>% 
  dplyr::mutate(line_number = as.numeric(substr(line, start = 1, stop = 1))) %>% 
  dplyr::mutate(id = rep(1:(n() / 2), each = 2),
                satellite = "terra")

tle <-
  rbind(aqua_tle, terra_tle)

# Info describing meaning of each character
# https://www.celestrak.com/NORAD/documentation/tle-fmt.php
# assign some attributes to each TLE so they can be properly subset and matched
# to the desired time of orbit prediction
tle_compact <-
  tle %>% 
  tidyr::pivot_wider(names_from = line_number, values_from = line) %>% 
  dplyr::rename(L1 = `1`, L2 = `2`) %>% 
  dplyr::mutate(yearstring = paste0("20", substr(L1, start = 19, stop = 20)),
                daystring = substr(L1, start = 21, stop = 32)) %>% 
  tidyr::separate(col = daystring, into = c("doy", "partial_day"), sep = "\\.") %>% 
  dplyr::mutate(partial_day = as.numeric(paste0("0.", partial_day)),
                doy = as.numeric(doy),
                hour_dec = 24 * partial_day,
                hour_int = floor(hour_dec),
                minute = round((hour_dec - hour_int) * 60),
                date = lubridate::ymd(paste0(yearstring, "-01-01"), tz = "zulu") + days(doy - 1) + hours(hour_int) + minutes(minute))


# complex orbital positions -----------------------------------------------

start_date <- ymd("2019-01-01", tz = "zulu")
n_periods <- 3

(start <- Sys.time())

# First create a column in a data.frame representing the minute-ly sequence of datetimes
# starting from the start date and continuing for an integer number of periods
# The position of Aqua at that datetime is determined by first figuring out which of the
# Aqua TLE is closest in time to the time we want to predict for.
# Using this TLE, we calculate the longitude, latitude, and altitude using pyorbital
# We iterate through all datetimes using the mapply() function
# Then, we do the same thing to get the Terra longitude, latitude, and altitude at that
# datetime.
# We turn the data into long form using pivot_longer such that each row/da
orbit_positions <-
  tibble(datetime = seq(start_date - minutes(1), start_date + days(n_periods * 16) - minutes(1), by = "1 min")) %>% 
  dplyr::mutate(aqua = mapply(FUN = function(x) {
    
    # find the TLE for Aqua closest to the time at which we want to predict satellite position
    closest_aqua_tle <-
      tle_compact %>% 
      dplyr::filter(satellite == "aqua") %>% 
      dplyr::filter(rank(abs(as.numeric(date - x)), ties.method = "first") == 1)
    
    # create an instance of the Orbital class that will let us make satellite position
    # predictions
    this_orbital_info <-
      orb$Orbital("EOS-Aqua", line1 = closest_aqua_tle$L1, line2 = closest_aqua_tle$L2)
    
    # get the longitude, latitude, and altitude of the satellite at datetime 'x'
    this_lonlatalt <- this_orbital_info$get_lonlatalt(x)
    
    # is the satellite on its ascending or descending node (based on velocity in the 'z'
    # direction; if positive, satellite is ascending south to north. If negative, satellite
    # is descending north to south)
    # useful for turning multipoints into linestrings representing the satellite path, which
    # is not currently implemented. That code can be retrieved if we want to go that route
    # instead. Basically, we turn each ascending or descending pass for each satellite into
    # its own linestring, then buffer those linestrings with the swath width of the satellites,
    # then use those noodle-looking orbit paths as polygons to rasterize. Challenging to get
    # both the poles and the equator to work well using this method!
    this_asc <- ifelse(this_orbital_info$get_position(x, normalize = FALSE)[[2]][3, ] > 0,
                       yes = "ascending_node",
                       no = "descending_node")
    
    return(list(c(this_lonlatalt, this_asc)))
    
  }, .$datetime),
  terra = mapply(FUN = function(x) {
    
    closest_terra_tle <-
      tle_compact %>%
      dplyr::filter(satellite == "terra") %>%
      dplyr::filter(rank(abs(as.numeric(date - x)), ties.method = "first") == 1)
    
    this_orbital_info <-
      orb$Orbital("EOS-Terra", line1 = closest_terra_tle$L1, line2 = closest_terra_tle$L2)
    
    this_lonlatalt <- this_orbital_info$get_lonlatalt(x)
    
    this_asc <- ifelse(this_orbital_info$get_position(x, normalize = FALSE)[[2]][3, ] > 0,
                       yes = "ascending_node",
                       no = "descending_node")
    
    return(list(c(this_lonlatalt, this_asc)))
    
  }, .$datetime)) %>%
  pivot_longer(cols = c(aqua, terra), names_to = "satellite", values_to = "location") %>%
  tidyr::hoist(.col = location, lon = 1, lat = 2, alt = 3, asc = 4)

(Sys.time() - start)


# make object spatial ---------------------------------------------------------------

orbit_sf <- 
  st_as_sf(orbit_positions, coords = c("lon", "lat"), crs = 4326, remove = FALSE)

# build bowties around each orbit position ---------------------------------------------------------------

sat_footprints <- 
  modis_bowtie_buffer(orbit_sf) %>% 
  st_wrap_dateline(options = c("WRAPDATELINE=YES", "DATELINEOFFSET=180")) %>% 
  st_cast("MULTIPOLYGON")

# rasterize the overlapping image footprints to a regular grid (using one of Joe's as
# a template)
r <- raster::raster("data/data_raw/mcd14ml-rasterized-template_0.25-degrees.tif")

orbit_overlap <- 
  fasterize::fasterize(sf = sat_footprints, raster = r, fun = "count")
orbit_overlap <- orbit_overlap / (n_periods * 16)

# visualize
plot(orbit_overlap, col = viridis(30))
plot(st_as_sf(ne_coastline()) %>% st_geometry(), add = TRUE)

# write to disk
dir.create("analyses/analyses_output")
writeRaster(x = orbit_overlap, filename = "analyses/analyses_output/aqua-terra-overpasses-per-day.tif")

# Build a table demonstrating the empirical function that maps latitude to expected number of overpasses
# per day
samps <-
  expand.grid(seq(-180, 180, by = 5), seq(-90, 90, by = 0.25)) %>% 
  setNames(c("lon", "lat")) %>% 
  as_tibble() %>% 
  dplyr::mutate(overpasses = extract(x = orbit_overlap, y = .)) %>% 
  dplyr::filter(!is.na(overpasses))

# include the range of observed overpasses as a minimum and maximum attribute
overpass_corrections <- 
  samps %>%
  group_by(lat) %>% 
  summarize(mean_overpasses = mean(overpasses),
            min_overpasses = min(overpasses),
            max_overpasses = max(overpasses))

# write to disk
write.csv(overpass_corrections, file = "data/data_output/aqua-terra-overpass-corrections-table.csv", row.names = FALSE)

# save the visualization to disk
png("figures/aqua-terra-overpass-corrections-map.png")
plot(orbit_overlap, col = viridis(30))
plot(st_as_sf(ne_coastline()) %>% st_geometry(), add = TRUE)
dev.off()

# save the empirical model plot to disk
png("figures/aqua-terra-overpass-corrections-function.png")
ggplot(overpass_corrections %>% filter(lat %in% c(seq(-83.5, -70, by = 0.25), -69:69, seq(70, 83.5, by = 0.25))), aes(x = lat, y = mean_overpasses)) +
  geom_point(cex = 0.3) +
  theme_bw() +
  geom_ribbon(aes(ymin = min_overpasses, ymax = max_overpasses), fill = "red", alpha = 0.1)
dev.off()