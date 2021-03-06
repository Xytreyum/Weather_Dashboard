if (!require("pacman")) install.packages("pacman")
pacman::p_load(shiny,
               leaflet,
               raster,
               lubridate,
               RMySQL,
               ggplot2,
               scales,
               stringr,
               reshape2,
               magrittr,
               grDevices,
               data.table)
source("functions.R")
# test
source("declarations.R")

rv <- reactiveValues(knmi_station_history = NULL,
                     metoffice_station_history=NULL,
                     windy_station_history=NULL,
                     click=NULL,
                     click_renewables_rt=NULL,
                     click_value=NULL,
                     ID_last_processed_time=Sys.time())

server <- function(input, output, session) {
    # autoInvalidates ----
    autoInvalidate_data_fetch_sql <- reactiveTimer(5 * 60 * 1000, session)
    autoInvalidate_MeteoSat <- reactiveTimer(3 * 60 * 1000, session)
    autoInvalidatrenewables_rt_graph <- reactiveTimer(1 * 60 * 1000, session)
    # Dataframes build up ----
    df_raw_sql <- reactive({
        # To update every x minutes, there is this autoInvalidate
        autoInvalidate_data_fetch_sql()
        input$refresh_data

        df_raw_sql <- withProgress(
            # This part takes care of showing the notifcation when data is fetched
            message='Importing data from DataHub',
            detail='Kind regards, Mathias',
            value=NULL,
            style='old',
            {
                # The actual data fetching
                import_data_sql_model(model=input$model)
            })
        return(df_raw_sql)
    })
    df_meteosat_sql_raw <- reactive({
        # To update every x minutes, there is this autoInvalidate
        autoInvalidate_data_fetch_sql()
        input$refresh_data
        compared_time <- compared_time()
        if (!isolate(input$Meteosat_rain) & !isolate(input$Meteosat_clouds) & !isolate(input$Meteosat_radiation) & !isolate(input$meteosat_compare_bool)){return(data.frame())}

        df_meteosat_sql_raw <- withProgress(
            # This part takes care of showing the notifcation when data is fetched
            message='Importing MeteoSat data from DataHub',
            detail='Kind regards, Luuk',
            value=NULL,
            style='old',
            {
                # The actual data fetching
                if(input$current_time) {
                    import_data_sql_meteosat(Sys.time(), 1, 1)
                }
                else {
                    import_data_sql_meteosat(compared_time, 1, 0.2)
                }
            })
        df_meteosat_sql_raw <- df_meteosat_sql_raw[df_meteosat_sql_raw$datetime == df_meteosat_sql_raw$datetime %>% max, ]
        return(df_meteosat_sql_raw)
    })
    df <- reactive({
        # From the raw data, get only the time that we want to show in the dashboard.
        # This will be the main dataframe from now on
        df_raw <- df_raw_sql()
        compared_time <- compared_time()

        # df_raw %>% head %>% print
        # compared_time %>% print
        df <- df_raw[df_raw$datetime == compared_time, ]
        # Convert to numeric if there is no warning. Station names will give a warning, therefore stay strings
        df <- lapply(df, function(x) tryCatch(x %>% as.numeric, warning =function(warning) x)) %>% data.frame
        return(df)
    })
    df_raw_sql_modelrun <- reactive({
        autoInvalidate_data_fetch_sql()
        if (!input$model_compare_bool) {return(data.frame())}
        df_raw_sql_modelrun <- withProgress(
            # This part takes care of showing the notifcation when data is fetched
            message='Importing modelrun data',
            detail='Happy holidays, Mathias',
            value=NULL,
            style='old',
            {
                # The actual data fetching
                import_data_sql_modelrun_compare(model=input$model)
            })


    })
    df_modelrun_compare_all <- reactive({
        df_raw_sql_modelrun <- df_raw_sql_modelrun()
        if (nrow(df_raw_sql_modelrun)==0) {print("df_raw_sql_modelrun empty"); return(data.frame())}
        compared_time <- compared_time()
        df_modelrun_compare_all <- df_raw_sql_modelrun[df_raw_sql_modelrun$datetime == compared_time, ]
        print(df_modelrun_compare_all %>% head)
        return(df_modelrun_compare_all)
    })
    df_modelrun_compare <- reactive({
        value.var = c('%s_temp', '%s_wind_speed', '%s_air_pressure', '%s_radiation') %>% sprintf(isolate(input$model) %>% tolower)

        df_modelrun_compare_all <- df_modelrun_compare_all()
        if (nrow(df_modelrun_compare_all)==0) {return(data.frame())}
        df_modelrun_compare <- dcast(setDT(df_modelrun_compare_all),
                                     datetime + lat + lon ~ model_date + model_run,
                                     value.var=value.var) %>%
            data.frame
        return(df_modelrun_compare)
    })

    compared_time <- reactive({
        # Get this into the autorefresh, so that the time will be updated when you are leaving it in live modus
        autoInvalidate_data_fetch_sql()
        # Determine the interesting time we want to show. Is used to filter df_raw into df
        # Depending on the switch, get the current time or the time the trader wants
        if(input$current_time) {
            # Get the current time, truncate it to hours so that we have the current hour
            compared_time <- Sys.time() %>%
                with_tz('UTC') %>%
                trunc('hour')
        } else {
            # Get time wanted by user by combining date and time.
            # Force to Localtime (assuming trader is located/thinking in Europe/Amsterdam time)
            # Convert to UTC to compare in dataframe coming from Datahub (which is in UTC)

            compared_time <- (input$date_input %>% as.POSIXct + input$hour_input * 60 * 60) %>%
                force_tz('Europe/Amsterdam') %>%
                with_tz('UTC')
        }
        return(compared_time)
    })

    model_observable <- reactive({
        if (input$model == 'GFS') {
            return(conversion_list_GFS[[input$observable]])}
        if (input$model == 'HIRLAM') {
            return(conversion_list_HIRLAM[[input$observable]])}
    })
    # Dataframes to be used in the dashboard ----
    df_model_raster <- reactive({
        df <- df()
        if(nrow(df)==0) {print("Nothing in raw df"); return(data.frame())}
        observable_fc <- model_observable()
        df_model_raster <- raster_maker(df, observable_fc)
        return(df_model_raster)
    })
    df_modelrun_compare_raster <- reactive({
        df_modelrun_compare <- df_modelrun_compare()
        if (nrow(df_modelrun_compare) == 0) {return(data.frame())}
        if ('loading' %in% c(input$modelrun_base, input$modelrun_comp)) {return(data.frame())}

        column_base <- change_input_to_column_name(input$modelrun_base, input$model, input$observable)
        column_comp <- change_input_to_column_name(input$modelrun_comp, input$model, input$observable)

        column_base %>% print
        column_comp %>% print
        if (!(column_base %in% names(df_modelrun_compare) & column_comp %in% names(df_modelrun_compare))) {return(data.frame())}
        df_modelrun_compare$diff <- df_modelrun_compare[[column_base]] - df_modelrun_compare[[column_comp]]
        raster_maker(df_modelrun_compare, 'diff')
    })
    df_modelrun_compare_meteosat_raster <- reactive({
        df <- df()
        df['lat'] =  round(df['lat'], 1)
        df['lon'] =  round(df['lon'], 1)
        if(nrow(df)==0) {print("Nothing in raw df"); return(data.frame())}
        if (input$model == 'GFS') {
            observable_fc <-(conversion_list_GFS[['Radiation']])}
        if (input$model == 'HIRLAM') {
            observable_fc <-(conversion_list_HIRLAM[['Radiation']])}

        df_meteosat_sql_raw <- df_meteosat_sql_raw()
        df_meteosat_sql_raw['lat'] =  round(df_meteosat_sql_raw['lat'], 1)
        df_meteosat_sql_raw['lon'] =  round(df_meteosat_sql_raw['lon'], 1)

        df_meteosat_sql_agg <-  setNames(aggregate(df_meteosat_sql_raw$sds, by=list(df_meteosat_sql_raw$lat,df_meteosat_sql_raw$lon), FUN=mean), c('lat','lon','sds'))
        df_merge <- merge(x = df_meteosat_sql_agg[ , c('lat','lon','sds')], y = df[ , c('lat','lon',observable_fc)] , by=c('lat','lon'))
        df_merge$diff <- df_merge[['sds']] - df_merge[[observable_fc]]
        raster_maker(df_merge, 'diff')
    })
    df_knmi <- reactive({
        df <- df()
        observable_knmi <- conversion_list_KNMI[[input$observable]]
        observable_fc <- model_observable()
        df_knmi <- df[!df[[observable_knmi]] %>% is.na,
                      c(observable_knmi, observable_fc, 'knmi_lat', 'knmi_lon', 'knmi_name')]
        df_knmi <- df_knmi[!duplicated(df_knmi), ]
        names(df_knmi)[c(1, 2)] <- c('knmi', 'model')
        df_knmi$dif <- df_knmi$knmi %>% as.numeric - df_knmi$model

        return(df_knmi)
    })
    df_owm <- reactive({
        df <- df()
        observable_owm <- conversion_list_OWM[[input$observable]]
        observable_fc <- model_observable()
        df_owm <- df[!df[[observable_owm]] %>% is.na,
                     c(observable_owm, observable_fc, 'owm_lat', 'owm_lon', 'owm_name')]
        df_owm <- df_owm[!duplicated(df_owm), ]
        names(df_owm)[c(1, 2)] <- c('owm', 'model')
        df_owm$dif <- df_owm$owm %>% as.numeric - df_owm$model

        return(df_owm)
    })
    df_metoffice <- reactive({
        df <- df()
        observable_metoffice <- conversion_list_MetOffice[[input$observable]]
        observable_fc <- model_observable()
        df_metoffice <- df[!df[[observable_metoffice]] %>% is.na,
                           c(observable_metoffice, observable_fc, 'metoffice_lat', 'metoffice_lon', 'metoffice_name')]
        df_metoffice <- df_metoffice[!duplicated(df_metoffice), ]
        names(df_metoffice)[c(1, 2)] <- c('metoffice', 'model')
        df_metoffice$dif <- df_metoffice$metoffice %>% as.numeric - df_metoffice$model

        return(df_metoffice)
    })
    df_windy <- reactive({
        df <- df()
        print (head(df))
        observable_windy <- conversion_list_Windy[[input$observable]]
        print (observable_windy)
        observable_fc <- model_observable()
        df_windy <- df[!df[[observable_windy]] %>% is.na,
                       c(observable_windy, observable_fc, 'windyrt_lat', 'windyrt_lon', 'windyrt_name')]
        df_windy <- df_windy[!duplicated(df_windy), ]
        names(df_windy)[c(1, 2)] <- c('windy', 'model')
        df_windy$dif <- df_windy$windy %>% as.numeric - df_windy$model

        return(df_windy)
    })
    df_Meteosat_cot_raster <- reactive({
        if (!input$Meteosat_clouds){return(data.frame())}
        df_meteosat_sql_raw <- df_meteosat_sql_raw()
        df_Meteosat_cot_raster <- raster_maker(df_meteosat_sql_raw, 'cot')
        return(df_Meteosat_cot_raster)
    })
    df_Meteosat_precip_raster <- reactive({
        if (!input$Meteosat_rain){return(data.frame())}
        df_meteosat_sql_raw <- df_meteosat_sql_raw()
        df_Meteosat_precip_raster <- raster_maker(df_meteosat_sql_raw, 'precip')
        return(df_Meteosat_precip_raster)
    })
    df_Meteosat_radiation_raster <- reactive({
        if (!input$Meteosat_radiation){return(data.frame())}
        df_meteosat_sql_raw <- df_meteosat_sql_raw()
        df_Meteosat_radiation_raster <- raster_maker(df_meteosat_sql_raw, 'sds')
        return(df_Meteosat_radiation_raster)
    })
    df_lines <- reactive({
        if(!input$isobars) {return()}
        column_model <- switch(isolate(input$model), # not sure if the isolate should be here, but df() is also updating
                               'GFS'='gfs_air_pressure',
                               'HIRLAM'='hirlam_air_pressure')

        df <- df()
        # deduplicate df due to multiple observations at one location
        df <- df[!(df[, c('lon', 'lat', column_model)]) %>% duplicated, ]
        df <- df[do.call('order', df[c('lat', 'lon')]), ]
        lon <- df$lon %>% unique #%>% sort
        lat <- df$lat %>% unique #%>% sort
        z <- matrix(df[[column_model]], length(lon), byrow=FALSE)
        lines <- contourLines(lon, lat, z, levels=seq(948,1052,4))

        return(lines)
    })
    # colorpalettes, domains and other boring stuff ----
    observeEvent({df_modelrun_compare_all(); input$model}, {
        df_modelrun_compare_all <- df_modelrun_compare_all()
        if (df_modelrun_compare_all %>% nrow == 0) {return()}
        df_modelrun_compare_all$model_date <- df_modelrun_compare_all$model_date %>%
            as.POSIXct()
        # Get unique combinations of model_date and model_run
        choices_raw = df_modelrun_compare_all[, c('model_date', 'model_run')] %>% unique
        # sort it
        choices_raw <- choices_raw[order(choices_raw$model_date, choices_raw$model_run) %>% rev, ]
        # Make it a format that is readable for Willem
        choices = paste0(strftime(choices_raw$model_date, "%d %b"),
                         sprintf(" (%02d)", choices_raw$model_run),
                         ifelse(choices_raw$model_run == 6, " (APX)", ""))
        choices = set_names(paste(choices_raw$model_date, choices_raw$model_run), choices)
        selected_base <- ifelse(input$modelrun_base %in% choices_raw,
                                input$modelrun_base,
                                choices[1])
        selected_comp <- ifelse(input$modelrun_comp %in% choices_raw,
                                input$modelrun_comp,
                                choices[2])
        updatePickerInput(session,
                          'modelrun_base',
                          choices=choices,
                          selected=selected_base)
        updatePickerInput(session,
                          'modelrun_comp',
                          choices=choices,
                          selected=selected_comp)
    })
    domain_model <- reactive ({
        list("Windspeed"=c(0, 25),
             "Temperature"=c(-10, 35),
             "Air pressure"=c(950, 1050),
             "Radiation"=c(0, 500))[[input$observable]]
    })
    cpalet_model_background <- reactive({
        options <- list("Windspeed"=colorNumeric(colorRampPalette(c("white", "white", "#66ffff", "#00ff99", "#00ff00", "#ffff00", "#ff9900", "#ff3300", "#ff0066", "#ff00ff"))(200),
                                                 domain = domain_model()),
                        "Temperature"=colorNumeric(palette = colorRampPalette(c("blue", "#66ffff", "white", "#ff9900", "red"))(200),
                                                   domain = domain_model()),
                        "Air pressure"=colorNumeric(palette = colorRampPalette(c("chartreuse", "lightpink", "aquamarine"))(200) ,
                                                    domain = domain_model()),
                        "Radiation"=colorBin(c("#3119b7", "#ffffff00", "yellow1"),
                                             domain=domain_model(),

                                             na.color="yellow1",
                                             bins=11))
        options[[input$observable]]

    })
    domain_diff <- reactive({
        list("Windspeed"=c(-5, 5),
             "Temperature"=c(-6, 6),
             "Air pressure"=c(-5, 5),
             "Radiation"=c(-150, 150))[[input$observable]]

    })
    cpalet_circlemarkers <- reactive({
        options <- list("Windspeed"=colorNumeric(palette = colorRampPalette(c("red", "#ff9900", "white", "#d8ff00" ,"limegreen"))(200) ,
                                                 domain = domain_diff()),
                        "Temperature"=colorNumeric(palette = colorRampPalette(c("blue", "#66ffff", "white", "#ff9900", "red"))(200) ,
                                                   domain = domain_diff()),
                        "Air pressure"=colorNumeric(palette = colorRampPalette(c("red", "#ff9900", "white", "#d8ff00", "limegreen"))(200) ,
                                                    domain = domain_diff()),
                        "Radiation"=colorNumeric(palette = colorRampPalette(c("blue", "white","yellow1"))(200) ,
                                                 domain = domain_diff()))
        options[[input$observable]]

    })
    # MAP ----
    output$map <- renderLeaflet({
        "Rendering Leaflet" %>% print

        a <- leaflet() %>%
            addTiles() %>%
            fitBounds(3.151613,53.670926,7.623049,50.719332)
        return(a)
    })
    observeEvent({df_model_raster(); input$model_compare_bool}, {
        if (isolate(input$model_compare_bool)) {
            # We want to compare thingies, so we do not need the 'normal' map
            return()
        }
        df_model_raster <- df_model_raster()
        leafletProxy('map') %>%
            clearGroup('model')
        if(df_model_raster %>% typeof == 'list') {
            # Returned empty from function before
            return()
        }
        leafletProxy('map') %>%
            # clearGroup('contourlines') %>%
            # clearGroup('HL') %>%
            addRasterImage(df_model_raster,
                           color=cpalet_model_background(),
                           opacity=0.5,
                           group='model') %>%
            addLegend(pal=cpalet_model_background(),
                      values=domain_model() %>% rev,
                      title=input$observable,
                      layerId='model_legend') %>%
            addLegend(pal=cpalet_circlemarkers(),
                      values=domain_diff() %>% rev,
                      title="Difference",
                      layerId='circlemarkers_legend')
    })
    observeEvent({df_modelrun_compare_raster(); input$model_compare_bool}, {
        if (!input$model_compare_bool) {
            # This plots the comparison, so the bool should be True!
            return()
        }
        df_modelrun_compare_raster <- df_modelrun_compare_raster()
        leafletProxy('map') %>%
            clearGroup('model')
        if (nrow(df_modelrun_compare_raster) == 0) {return()}
        leafletProxy('map') %>%
            clearControls %>%
            addRasterImage(df_modelrun_compare_raster,
                           color=cpalet_circlemarkers(),
                           opacity=0.5,
                           group='model') %>%
            addLegend(pal=cpalet_circlemarkers(),
                      values=domain_diff() %>% rev,
                      title=sprintf("%s diff", input$observable),
                      layerId='model_legend')
    })
    observeEvent({input$meteosat_compare_bool}, {
        if (!input$meteosat_compare_bool) {
            # This plots the comparison, so the bool should be True!
            return()
        }
        df_modelrun_compare_meteosat_raster <- df_modelrun_compare_meteosat_raster()
        leafletProxy('map') %>%
            clearGroup('model')
        if (nrow(df_modelrun_compare_meteosat_raster) == 0) {return()}
        leafletProxy('map') %>%
            clearControls %>%
            addRasterImage(df_modelrun_compare_meteosat_raster,
                           color=cpalet_circlemarkers(),
                           opacity=0.5,
                           group='model') %>%
            addLegend(pal=cpalet_circlemarkers(),
                      values=domain_diff() %>% rev,
                      title=sprintf("%s diff", 'Radiation'),
                      layerId='model_legend')
    })
    observeEvent({df_Meteosat_cot_raster(); input$Meteosat_clouds}, {
        df_Meteosat_cot_raster <- df_Meteosat_cot_raster()
        leafletProxy('map') %>%
            clearGroup('MeteoSat_cot')
        if(df_Meteosat_cot_raster %>% typeof == 'list') {
            # Returned empty from function before
            return()
        }
        leafletProxy('map') %>%
            # clearGroup('contourlines') %>%
            # clearGroup('HL') %>%
            addRasterImage(log10(df_Meteosat_cot_raster),
                           color=colors_MeteoSat_cot,
                           opacity=0.45,
                           group='MeteoSat_cot')
    })
    observeEvent({df_Meteosat_precip_raster(); input$Meteosat_rain}, {
        df_Meteosat_precip_raster <- df_Meteosat_precip_raster()
        leafletProxy('map') %>%
            clearGroup('MeteoSat_precip')
        if(df_Meteosat_precip_raster %>% typeof == 'list') {
            # Returned empty from function before
            return()
        }
        leafletProxy('map') %>%
            # clearGroup('contourlines') %>%
            # clearGroup('HL') %>%
            addRasterImage(log10(df_Meteosat_precip_raster),
                           color=colors_MeteoSat_precip,
                           opacity=0.45,
                           group='MeteoSat_precip')
    })
    observeEvent({df_Meteosat_radiation_raster(); input$Meteosat_radiation}, {
        df_Meteosat_radiation_raster <- df_Meteosat_radiation_raster()
        leafletProxy('map') %>%
            clearGroup('MeteoSat_radiation')
        if(df_Meteosat_radiation_raster %>% typeof == 'list') {
            # Returned empty from function before
            return()
        }
        leafletProxy('map') %>%
            # clearGroup('contourlines') %>%
            # clearGroup('HL') %>%
            addRasterImage((df_Meteosat_radiation_raster),
                           color=colors_MeteoSat_radiation,
                           opacity=0.45,
                           group='MeteoSat_radiation')
    })
    observeEvent({df_knmi(); input$knmi_switch}, {
        leafletProxy('map') %>%
            clearGroup('KNMI_markers')

        if (!input$knmi_switch) {
            # No need to do anything else
            return()
        }
        print("Plotting KNMI markers")
        df_knmi <- df_knmi()

        leafletProxy('map') %>%
            # clearGroup("KNMI_markers") %>%
            addCircleMarkers(lat=df_knmi$knmi_lat,
                             lng=df_knmi$knmi_lon,
                             radius=8,
                             weight=1,
                             popup=paste0("KNMI", "<br>",
                                          "stationname: ", df_knmi$knmi_name, "<br>",
                                          "KNMI:: ", df_knmi$knmi %>% round(2),"<br>",
                                          "Model: ", df_knmi$model %>% round(2)),
                             fillColor=suppressWarnings(cpalet_circlemarkers()(df_knmi$dif)),
                             color='black',
                             fillOpacity=1,
                             opacity=1,
                             group='KNMI_markers',
                             layerId=df_knmi$knmi_name)
    })
    observeEvent({df_owm(); input$owm_switch}, {
        leafletProxy('map') %>%
            clearGroup('OWM_markers')

        if (!input$owm_switch) {
            # No need to do anything else
            return()
        }
        print("Plotting OWM markers")
        df_owm <- df_owm()

        leafletProxy('map') %>%
            # clearGroup("KNMI_markers") %>%
            addCircleMarkers(lat=df_owm$owm_lat,
                             lng=df_owm$owm_lon,
                             radius=8,
                             weight=1,
                             popup=paste0("OWM", "<br>",
                                          "stationname: ", df_owm$owm_name, "<br>",
                                          "OWM: ", df_owm$owm %>% round(2),"<br>",
                                          "Model: ", df_owm$model %>% round(2)),
                             fillColor=suppressWarnings(cpalet_circlemarkers()(df_owm$dif)),
                             color='orange',
                             fillOpacity=1,
                             opacity=1,
                             group='OWM_markers',
                             layerId=df_owm$owm_name)
    })
    observeEvent({df_metoffice(); input$metoffice_switch}, {
        leafletProxy('map') %>%
            clearGroup('MetOffice_markers')

        if (!input$metoffice_switch) {
            # No need to do anything else
            return()
        }
        print("Plotting MetOffice markers")
        df_metoffice <- df_metoffice()

        leafletProxy('map') %>%
            # clearGroup("KNMI_markers") %>%
            addCircleMarkers(lat=df_metoffice$metoffice_lat,
                             lng=df_metoffice$metoffice_lon,
                             radius=8,
                             weight=1,
                             popup=paste0("MetOffice", "<br>",
                                          "stationname: ", df_metoffice$metoffice_name, "<br>",
                                          "MetOffice:: ", df_metoffice$metoffice %>% round(2),"<br>",
                                          "Model: ", df_metoffice$model %>% round(2)),
                             fillColor=suppressWarnings(cpalet_circlemarkers()(df_metoffice$dif)),
                             color='white',
                             fillOpacity=1,
                             opacity=1,
                             group='MetOffice_markers',
                             layerId=df_metoffice$metoffice_name)
    })
    observeEvent({df_windy(); input$windy_switch}, {
        leafletProxy('map') %>%
            clearGroup('Windy_markers')

        if (!input$windy_switch) {
            # No need to do anything else
            return()
        }
        print("Plotting Windy markers")
        df_windy <- df_windy()

        leafletProxy('map') %>%
            addCircleMarkers(lat=df_windy$windyrt_lat,
                             lng=df_windy$windyrt_lon,
                             radius=8,
                             weight=1,
                             popup=paste0("Windy", "<br>",
                                          "stationname: ", df_windy$windyrt_name, "<br>",
                                          "Windy:: ", df_windy$windy %>% round(2),"<br>",
                                          "Model: ", df_windy$model %>% round(2)),
                             fillColor=suppressWarnings(cpalet_circlemarkers()(df_windy$dif)),
                             color='white',
                             fillOpacity=1,
                             opacity=1,
                             group='Windy_markers',
                             layerId=df_windy$windyrt_name)
    })
    observeEvent({input$wind_rt}, {
        leafletProxy('map') %>%
            clearGroup('wind_rt')
        if (!input$wind_rt) {
            # Done here!
            return()
        }

        icons_size <- icons(
            iconUrl=windparkiconurl_wind_rt,
            iconHeight = 20,
            iconWidth = 20
        )
        leafletProxy('map') %>%
            addMarkers(lat = append(wind_rt_location$lat, 51.53987),
                       lng = append(wind_rt_location$lon, 2.92185),
                       icon = icons_size,
                       group="wind_rt",
                       layerId=append(wind_rt_location$aggregateId, 999))

    })
    observeEvent({input$solar_rt}, {
        leafletProxy('map') %>%
            clearGroup('solar_rt')
        if (!input$solar_rt) {
            # Done here!
            return()
        }

        icons_size <- icons(
            iconUrl=solarparkiconurl_solar_rt,
            iconHeight = 15,
            iconWidth = 15
        )
        leafletProxy('map') %>%
            addMarkers(lat = solar_rt_location$lat,
                       lng = solar_rt_location$lon,
                       icon = icons_size,
                       group="solar_rt",
                       layerId=solar_rt_location$park_id)
    })
    observeEvent({input$windparks_Eneco}, {
        leafletProxy('map') %>%
            clearGroup('eneco_windparks')
        if (!input$windparks_Eneco) {
            # Done here!
            return()
        }

        icons_size <- icons(
            iconUrl=windparkiconurl,
            iconHeight = 20 * Windparks$max_MW / Windparks$max_MW %>% max + 20,
            iconWidth = 20 * Windparks$max_MW / Windparks$max_MW %>% max + 20
        )
        leafletProxy('map') %>%
            addMarkers(lat = Windparks$lat,
                       lng = Windparks$lon,
                       icon = icons_size,
                       popup=paste0(Windparks$Location, "<br>",
                                    "capacity: ", Windparks$max_MW," MW<br>"
                       ),
                       group="eneco_windparks")

    })
    observeEvent({input$windparks_External}, {
        leafletProxy('map') %>%
            clearGroup('external_windparks')
        if (!input$windparks_External) {
            # Done here!
            return()
        }

        icons_size <- icons(
            iconUrl=windparkiconurl_grey,
            iconHeight = 20 * external_windparks$max_MW / external_windparks$max_MW %>% max + 20,
            iconWidth = 20 * external_windparks$max_MW / external_windparks$max_MW %>% max + 20
        )
        leafletProxy('map') %>%
            addMarkers(lat = external_windparks$lat,
                       lng = external_windparks$lon,
                       icon = icons_size,
                       popup=paste0(external_windparks$PARK, "<br>",
                                    "Owner: ", external_windparks$OWNER, "<br>",
                                    "capacity: ", external_windparks$max_MW," MW<br>"),
                       group="external_windparks")

    })
    observeEvent({df(); input$wind_direction}, {
        leafletProxy('map') %>%
            clearGroup('wind_direction')
        if (!input$wind_direction) {
            # Done here!
            return()
        }
        df <- df()
        df_wind <- df[df$lat %% 1 ==0 & df$lon %% 1 == 0, ]
        icon <- icons(wind_directions_location[if (input$model == 'GFS'){df_wind$gfs_wind_direction}
                                               else if (input$model == 'HIRLAM'){df_wind$hirlam_wind_direction} %>%
                                                   divide_by(22.5) %>%
                                                   round(0) %>%
                                                   multiply_by(22.5) %>%
                                                   round(0) %% 360 %>%
                                                   as.character],
                      iconHeight=30,
                      iconWidth=30)
        leafletProxy('map') %>%
            addMarkers(lng=df_wind$lon,
                       lat=df_wind$lat,
                       icon=icon,
                       popup=NULL,
                       group='wind_direction')


    })
    observeEvent({df_lines(); input$isobars}, {
        leafletProxy('map') %>%
            clearGroup('isobars')
        print('Plotting lines')
        if (!input$isobars) {return()}

        df_lines <- df_lines()
        for (line in df_lines) {
            lng=line$x
            lng = c(lng, rev(lng))
            lat=line$y
            lat = c(lat, rev(lat))
            leafletProxy('map') %>%
                addPolylines(lng=lng,
                             lat=lat,
                             fill=FALSE,
                             color='black',
                             weight=2,
                             opacity=1,
                             options=pathOptions(lineJoin = TRUE),
                             group='isobars')

            # Change this number to change the number of markers denoting the value
            places <- (c(3) /6 * length(line$x)) %>% round
            line <- line %>% data.frame
            leafletProxy('map') %>%
                addLabelOnlyMarkers(data=line[places, ],
                                    lng=~x,
                                    lat=~y,
                                    label=~as.character(level),
                                    labelOptions = labelOptions(noHide=T,
                                                                direction='top',
                                                                textOnly=T,
                                                                textsize="18px"),
                                    group='isobars')
        }
        df <- df()
        column_model <- switch(isolate(input$model),
                               'GFS'='gfs_air_pressure',
                               'HIRLAM'='hirlam_air_pressure')
        dataH <- df[(df[[column_model]] %>% max) == df[[column_model]], ]
        dataH <- dataH[sample(nrow(dataH), 1), ]
        dataH$text <- 'H'
        dataL <- df[(df[[column_model]] %>% min) == df[[column_model]], ]
        dataL <- dataL[sample(nrow(dataL), 1), ]
        dataL$text <- 'L'
        leafletProxy('map') %>%
            addLabelOnlyMarkers(data=dataH,
                                lng=~lon,
                                lat=~lat,
                                label=~as.character(text),
                                labelOptions = labelOptions(noHide = T,
                                                            direction = 'top',
                                                            textOnly = T,
                                                            textsize="50px"),
                                group='isobars')
        leafletProxy('map') %>%
            addLabelOnlyMarkers(data=dataL,
                                lng=~lon,
                                lat=~lat,
                                label=~as.character(text),
                                labelOptions = labelOptions(noHide = T,
                                                            direction = 'top',
                                                            textOnly = T,
                                                            textsize="50px"),
                                group='isobars')
    })
    observeEvent({input$map_marker_click}, {
        click <- input$map_marker_click
        groups_that_can_click <- c('KNMI_markers', 'MetOffice_markers', 'OWM_markers','Windy_markers')
        if(click$group %in% groups_that_can_click) {
            # Only groups_that_can_click should change the status of rv$click to make sure that the graph lasts
            rv$click <<- click
        }
        if (click$group == "wind_rt" | click$group == "solar_rt") {
            rv$click_renewables_rt <<- click
        }
    })
    observeEvent({input$map_click}, {
        click <- input$map_click
        rv$click_value <<- click
    })
    # Complementary stuff ----
    output$compared_time <- renderText({
        compared_time() %>%
            with_tz('Europe/Amsterdam') %>%
            strftime("%d %b %H:%M", tz='Europe/Amsterdam')
    })
    output$click_value <- renderText({
        if (is.null(rv$click_value)) {return(NULL)}
        coordinates <- convert_click_to_coordinates(rv$click_value)
        frame = cbind.data.frame(coordinates$lat, coordinates$lon)
        coordinates(frame) <- ~coordinates$lon + coordinates$lat
        click_value <- ifelse(input$model_compare_bool,
                              extract(df_modelrun_compare_raster(), frame) %>% round(2),
                              extract(df_model_raster(), frame) %>% round(2))
        return(sprintf('Click value: %.2f', click_value))
    })
    output$observation_history_plot <- renderPlot({
        # do checks if the click is empty/NULL
        click <- rv$click
        if(is.null(click)) {
            # No plot necessary
            return()
        }

        # Datetime of begin/end of the day
        datetimes <- get_datetimes_history()
        # Get df to select the right stationname
        df <- isolate(df())

        p <- withProgress(
            # This part takes care of showing the notifcation when data is gathered and picture created
            message='Creating history',
            detail='Yours sincerely, Mathias',
            value=NULL,
            style='old',
            {
                # The picture creation
                create_observation_history_plot(click, datetimes, df, input$observable)
            })
        return(p)
    })
    output$renewables_rt_plot <- renderPlot({
        click <- rv$click_renewables_rt
        autoInvalidatrenewables_rt_graph()
        if(is.null(click)) {
            # No plot necessary
            return()
        }
        datetime_begin <- (Sys.time() - 3 * 60 * 60) %>% with_tz('UTC') %>% strftime('%Y-%m-%d %H:%M:%S')
        if(click$group == "wind_rt") {
            if(click$id == 999) {
                stmt <- sprintf("select datetime, sum(actual_active_power) as value from breeze.c_power where datetime >= '%s' group by datetime;",
                                datetime_begin)
                df <- run.query(stmt, 'C-Power RT power')$result
            }
            else {
                stmt <- sprintf("SELECT datetime, datasignalValue as value, sitename from breeze.breeze_power_data_source WHERE aggregateId = %s AND datetime >= '%s'",
                                click$id,
                                datetime_begin)
                df <- run.query(stmt, 'Breeze RT power')$result
            }
        }
        else if(click$group == "solar_rt") {
            stmt <- sprintf("SELECT se.datetime, se.park_id, sd.park_name AS sitename, se.yield_inverter AS value FROM synaptiq.solar_energy_data_source se INNER JOIN mapping.solar_parks_details sd ON se.park_id=sd.park_id WHERE se.park_id = %s AND se.datetime >= '%s'",
                            click$id,
                            datetime_begin)
            df <- run.query(stmt, 'Synaptiq RT power')$result
        }
        df$datetime <- df$datetime %>%
            as.POSIXct() %>%
            with_tz('Europe/Amsterdam')
        if(click$group == "wind_rt") {
            df$value <- df$value / 1000
            yaxis_label <- 'Wind Power (MW)'
        }
        else if(click$group == "solar_rt") {
            df$value <- df$value
            yaxis_label <- 'Solar Power (kW)'
        }
        p <- ggplot() +
            geom_line(data=df, aes(x=datetime,
                                   y=value),
                      color='red')
        if(click$group == "wind_rt") {
            p <- p + geom_hline(yintercept=wind_rt_location[wind_rt_location$aggregateId == click$id, 'nominal_power'] / 1000)
            if(click$id == 999) {
                p <- p + geom_hline(yintercept=174)
            }
        }
        else if(click$group == "solar_rt") {
            p <- p + geom_hline(yintercept=solar_rt_location[solar_rt_location$park_id == click$id, 'nominal_power'])
        }
        p <- p +
            scale_x_datetime(expand=c(0, 0),
                             breaks=date_breaks('1 hours'),
                             labels=date_format("%H:%M", tz='Europe/Amsterdam')) +
            ylab(yaxis_label) +
            xlab('Time') +
            ggtitle(df$sitename[1])
        if (df$value %>% min > 0) {
            p <- p + scale_y_continuous(expand=c(0,0), limits=c(0, ggplot_build(p)$layout$panel_ranges[[1]]$y.range[[2]]))
        }
        return(p)
    })

}
