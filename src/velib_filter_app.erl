%%%-------------------------------------------------------------------
%%% @doc Paris Vélib real-time availability agent.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(velib_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(VELIB_API_URL,
    "https://opendata.paris.fr/api/records/1.0/search/"
    "?dataset=velib-disponibilite-en-temps-reel").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"velib">>, <<"realtime">>,
                                      <<"paris">>, <<"mobility">>, <<"bikes">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(velib_filter, ?MODULE, #{
        capabilities => base_capabilities()
    }),
    {ok, self()}.

stop(_State) ->
    em_filter:stop_agent(velib_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout, MaxResults, StatusFilter, MinBikes, MaxBikes, MinDocks}
        = extract_params(JsonBinary),
    Stations = fetch_velib_stations(MaxResults * 3, Timeout),
    Filtered = apply_filters(Stations, #{
        search_query  => Value,
        status_filter => StatusFilter,
        min_bikes     => MinBikes,
        max_bikes     => MaxBikes,
        min_docks     => MinDocks
    }),
    lists:sublist(Filtered, MaxResults).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value        = binary_to_list(maps:get(<<"value">>,         Map, <<"">>)),
            Timeout      = parse_int(maps:get(<<"timeout">>,      Map, 10),  10),
            MaxResults   = parse_int(maps:get(<<"max_results">>,   Map, 50),  50),
            StatusFilter = maps:get(<<"status_filter">>, Map, <<"all">>),
            MinBikes     = parse_int(maps:get(<<"min_bikes">>,     Map, 0),   0),
            MaxBikes     = parse_int(maps:get(<<"max_bikes">>,     Map, 999), 999),
            MinDocks     = parse_int(maps:get(<<"min_docks">>,     Map, 0),   0),
            {Value, Timeout, MaxResults, StatusFilter, MinBikes, MaxBikes, MinDocks};
        _ ->
            {binary_to_list(JsonBinary), 10, 50, <<"all">>, 0, 999, 0}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10, 50, <<"all">>, 0, 999, 0}
    end.

parse_int(V, _Default) when is_integer(V) -> V;
parse_int(V, Default) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> Default end;
parse_int(_, Default) -> Default.

fetch_velib_stations(MaxResults, TimeoutSecs) ->
    Url = ?VELIB_API_URL ++ "&rows=" ++ integer_to_list(MaxResults),
    case httpc:request(get, {Url, []},
                       [{timeout, TimeoutSecs * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_velib_response(Body);
        _ ->
            []
    end.

parse_velib_response(JsonBody) ->
    try json:decode(JsonBody) of
        #{<<"records">> := Records} when is_list(Records) ->
            lists:filtermap(fun create_embryo/1, Records);
        _ -> []
    catch
        _:_ -> []
    end.

create_embryo(Record) ->
    try
        Fields    = maps:get(<<"fields">>, Record, #{}),
        Name      = maps:get(<<"name">>,              Fields, <<"Unknown Station">>),
        Bikes     = maps:get(<<"numbikesavailable">>, Fields, 0),
        Docks     = maps:get(<<"numdocksavailable">>, Fields, 0),
        Installed = maps:get(<<"is_installed">>,      Fields, <<"NON">>),
        Resume    = case Installed of
            <<"OUI">> ->
                Status = station_status(Bikes, Docks),
                fmt("Station ~s: ~p bikes available, ~p docks free (~s)",
                    [Name, Bikes, Docks, Status]);
            _ ->
                fmt("Station ~s: Currently not in service", [Name])
        end,
        {true, #{
            <<"properties">> => #{
                <<"url">>    => <<"https://www.velib-metropole.fr/">>,
                <<"resume">> => list_to_binary(Resume),
                <<"name">>   => Name,
                <<"bikes">>  => Bikes,
                <<"docks">>  => Docks
            }
        }}
    catch
        _:_ -> false
    end.

station_status(Bikes, Docks) ->
    Total = Bikes + Docks,
    if Total =:= 0  -> "maintenance";
       Bikes =:= 0  -> "empty";
       Docks =:= 0  -> "full";
       Bikes =< 2   -> "low bikes";
       Docks =< 2   -> "almost full";
       true         -> "normal"
    end.

apply_filters(Stations, Filters) ->
    lists:filter(fun(S) -> match_all(S, Filters) end, Stations).

match_all(#{<<"properties">> := Props}, Filters) ->
    Name   = binary_to_list(maps:get(<<"name">>,   Props, <<"">>)),
    Bikes  = maps:get(<<"bikes">>, Props, 0),
    Docks  = maps:get(<<"docks">>, Props, 0),
    Resume = binary_to_list(maps:get(<<"resume">>, Props, <<"">>)),
    Status = case re:run(Resume, "\\(([^)]+)\\)", [{capture, [1], list}]) of
        {match, [S]} -> S;
        _            -> "unknown"
    end,
    Query        = maps:get(search_query,  Filters),
    StatusFilter = maps:get(status_filter, Filters),
    MinBikes     = maps:get(min_bikes,     Filters),
    MaxBikes     = maps:get(max_bikes,     Filters),
    MinDocks     = maps:get(min_docks,     Filters),
    match_query(Name, Resume, Query)   andalso
    match_status(Status, StatusFilter) andalso
    Bikes >= MinBikes andalso Bikes =< MaxBikes andalso
    Docks >= MinDocks;
match_all(_, _) -> false.

match_query(_Name, _Resume, "")     -> true;
match_query(Name, Resume, Query) ->
    Low = string:to_lower(Query),
    string:str(string:to_lower(Name),   Low) > 0 orelse
    string:str(string:to_lower(Resume), Low) > 0.

match_status(_Status, <<"all">>) -> true;
match_status(Status, Filter) ->
    string:equal(Status, binary_to_list(Filter)).

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).
