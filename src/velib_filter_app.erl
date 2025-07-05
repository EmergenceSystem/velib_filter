-module(velib_filter_app).
-behaviour(application).
-behaviour(cowboy_handler).

%% Application callbacks
-export([start/2, stop/1]).

%% Cowboy handler callbacks
-export([init/2, terminate/3]).

%% Paris Vélib public API (no API key required)
-define(VELIB_API_URL, "https://opendata.paris.fr/api/records/1.0/search/?dataset=velib-disponibilite-en-temps-reel").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(velib_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% Cowboy handler behavior
init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("Received body: ~p~n", [Body]),
    EmbryoList = generate_velib_data(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% Generate embryo list from API request with filtering capabilities
generate_velib_data(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Request when is_map(Request) ->
            % Parse request parameters - using same structure as Bing filter
            SearchValue = maps:get(value, Request, <<"">>),
            Timeout = parse_integer_param(maps:get(timeout, Request, <<"10">>)),
            
            % Additional filter parameters (optional)
            MaxResults = parse_integer_param(maps:get(max_results, Request, <<"50">>)),
            StatusFilter = maps:get(status_filter, Request, <<"all">>),
            MinBikes = parse_integer_param(maps:get(min_bikes, Request, <<"0">>)),
            MaxBikes = parse_integer_param(maps:get(max_bikes, Request, <<"999">>)),
            MinDocks = parse_integer_param(maps:get(min_docks, Request, <<"0">>)),

            io:format("Fetching Vélib data with search filter: ~p, timeout: ~p~n", [SearchValue, Timeout]),
            
            % Fetch more data than needed to allow proper filtering
            AllStations = fetch_velib_stations(MaxResults * 3, Timeout),
            
            % Apply search filter - primary filter is the search value
            FilteredStations = apply_search_filters(AllStations, #{
                search_query => SearchValue,
                status_filter => StatusFilter,
                min_bikes => MinBikes,
                max_bikes => MaxBikes,
                min_docks => MinDocks
            }),
            
            % Limit final results to requested amount
            lists:sublist(FilteredStations, MaxResults);
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

%% Helper function to parse integer parameters that might be binary or string
parse_integer_param(Value) when is_binary(Value) ->
    try
        list_to_integer(binary_to_list(Value))
    catch
        _:_ -> 0
    end;
parse_integer_param(Value) when is_list(Value) ->
    try
        list_to_integer(Value)
    catch
        _:_ -> 0
    end;
parse_integer_param(Value) when is_integer(Value) ->
    Value;
parse_integer_param(_) ->
    0.

%% Apply search filters to station list
apply_search_filters(Stations, Filters) ->
    lists:filter(fun(Station) ->
        match_all_filters(Station, Filters)
    end, Stations).

%% Check if a station matches all filter criteria
match_all_filters(Station, Filters) ->
    StationData = extract_station_data(Station),
    
    % Station must match all criteria to be included
    % Primary filter is the search query (e.g., "Benjamin")
    match_search_query(StationData, maps:get(search_query, Filters)) andalso
    match_status_filter(StationData, maps:get(status_filter, Filters)) andalso
    match_bike_range(StationData, maps:get(min_bikes, Filters), maps:get(max_bikes, Filters)) andalso
    match_dock_minimum(StationData, maps:get(min_docks, Filters)).

%% Extract structured data from station embryo for filtering
extract_station_data(#{properties := #{<<"resume">> := Resume}}) ->
    % Parse resume string to extract station data
    ResumeStr = binary_to_list(Resume),
    
    % Extract station name (between "Station " and ":")
    StationName = case string:str(ResumeStr, "Station ") of
        0 -> "";
        Pos -> 
            NameStart = Pos + 8,
            case string:str(string:substr(ResumeStr, NameStart), ":") of
                0 -> string:substr(ResumeStr, NameStart);
                ColonPos -> string:substr(ResumeStr, NameStart, ColonPos - 1)
            end
    end,
    
    % Extract number of available bikes
    Bikes = case re:run(ResumeStr, "(\\d+) bikes available", [{capture, all_but_first, list}]) of
        {match, [BikeStr]} -> list_to_integer(BikeStr);
        _ -> 0
    end,
    
    % Extract number of free docks
    Docks = case re:run(ResumeStr, "(\\d+) docks free", [{capture, all_but_first, list}]) of
        {match, [DockStr]} -> list_to_integer(DockStr);
        _ -> 0
    end,
    
    % Extract status from parentheses
    Status = case re:run(ResumeStr, "\\(([^)]+)\\)", [{capture, all_but_first, list}]) of
        {match, [StatusStr]} -> StatusStr;
        _ -> 
            case string:str(ResumeStr, "not in service") of
                0 -> "unknown";
                _ -> "maintenance"
            end
    end,
    
    #{
        name => StationName,
        bikes => Bikes,
        docks => Docks,
        status => Status,
        resume => ResumeStr
    }.

%% Filter by text search in station name (case-insensitive)
match_search_query(_StationData, <<"">>) -> true;
match_search_query(#{name := Name}, SearchQuery) ->
    QueryStr = string:to_lower(binary_to_list(SearchQuery)),
    NameStr = string:to_lower(Name),
    % Match if the search term is found anywhere in the station name
    string:str(NameStr, QueryStr) > 0;
match_search_query(#{resume := Resume}, SearchQuery) ->
    % Also search in the full resume text as fallback
    QueryStr = string:to_lower(binary_to_list(SearchQuery)),
    ResumeStr = string:to_lower(Resume),
    string:str(ResumeStr, QueryStr) > 0.

%% Filter by station status
match_status_filter(_StationData, <<"all">>) -> true;
match_status_filter(#{status := Status}, StatusFilter) ->
    FilterStr = binary_to_list(StatusFilter),
    string:equal(Status, FilterStr).

%% Filter by bike availability range
match_bike_range(#{bikes := Bikes}, MinBikes, MaxBikes) ->
    Bikes >= MinBikes andalso Bikes =< MaxBikes.

%% Filter by minimum dock availability
match_dock_minimum(#{docks := Docks}, MinDocks) ->
    Docks >= MinDocks.

%% Fetch real Vélib station data from Paris Open Data API
fetch_velib_stations(MaxResults, TimeoutSecs) ->
    Url = ?VELIB_API_URL ++ "&rows=" ++ integer_to_list(MaxResults),

    case httpc:request(get, {Url, []}, [{timeout, TimeoutSecs * 1000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            io:format("Received Vélib API response. Body length: ~p~n", [byte_size(Body)]),
            parse_velib_response(Body);
        {error, Reason} ->
            io:format("Error fetching Vélib data: ~p~n", [Reason]),
            % Fallback to sample embryos if API fails
            generate_sample_velib_embryos()
    end.

%% Parse JSON response from Vélib API and create embryo objects
parse_velib_response(JsonBody) ->
    try
        case jsone:decode(JsonBody, [{keys, atom}]) of
            #{records := Records} ->
                EmbryoList = lists:map(fun create_embryo_from_station/1, Records),
                lists:filter(fun(Embryo) -> Embryo =/= skip end, EmbryoList);
            _ ->
                io:format("Unexpected JSON structure~n"),
                generate_sample_velib_embryos()
        end
    catch
        _:Error ->
            io:format("Error parsing Vélib response: ~p~n", [Error]),
            generate_sample_velib_embryos()
    end.

%% Create embryo object from a single station record
create_embryo_from_station(Record) ->
    try
        Fields = maps:get(fields, Record, #{}),
        StationName = maps:get(name, Fields, <<"Unknown Station">>),
        AvailableBikes = maps:get(numbikesavailable, Fields, 0),
        AvailableDocks = maps:get(numdocksavailable, Fields, 0),
        IsInstalled = maps:get(is_installed, Fields, <<"NON">>),

        Resume = case IsInstalled of
            <<"OUI">> ->
                Status = get_station_status(AvailableBikes, AvailableDocks),
                list_to_binary(io_lib:format("Station ~s: ~p bikes available, ~p docks free (~s)",
                    [StationName, AvailableBikes, AvailableDocks, Status]));
            _ ->
                list_to_binary(io_lib:format("Station ~s: Currently not in service", [StationName]))
        end,

        #{
            properties => #{
                <<"resume">> => Resume
            }
        }
    catch
        _:_ ->
            skip
    end.

%% Determine station status based on availability
get_station_status(Bikes, Docks) ->
    Total = Bikes + Docks,
    if
        Total == 0 -> "maintenance";
        Bikes == 0 -> "empty";
        Docks == 0 -> "full";
        Bikes =< 2 -> "low bikes";
        Docks =< 2 -> "almost full";
        true -> "normal"
    end.

%% Generate sample embryo data when API is not available
generate_sample_velib_embryos() ->
    SampleData = [
        <<"Station Benjamin Franklin: 8 bikes available, 12 docks free (normal)">>,
        <<"Station République: 1 bikes available, 18 docks free (low bikes)">>,
        <<"Station Châtelet: 15 bikes available, 5 docks free (normal)">>,
        <<"Station Benjamin Constant: 0 bikes available, 20 docks free (empty)">>,
        <<"Station Gare du Nord: 12 bikes available, 8 docks free (normal)">>,
        <<"Station Montmartre: 6 bikes available, 1 docks free (almost full)">>,
        <<"Station Benjamin Rabier: 9 bikes available, 11 docks free (normal)">>,
        <<"Station Opéra: Currently not in service">>,
        <<"Station Saint-Benjamin: 5 bikes available, 15 docks free (normal)">>,
        list_to_binary(io_lib:format("Data updated: ~s", [format_current_time()]))
    ],

    lists:map(fun(Resume) ->
        #{
            properties => #{
                <<"resume">> => Resume
            }
        }
    end, SampleData).

%% Format current timestamp
format_current_time() ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:local_time(),
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
        [Year, Month, Day, Hour, Minute, Second]).
