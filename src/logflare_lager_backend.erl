-module(logflare_lager_backend).

-include_lib("lager/include/lager.hrl").

-behaviour(gen_event).

-export([
         init/1,
         handle_call/2,
         handle_event/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-record(state, {
                id :: term(),
                level :: undefined | {'mask', integer()},
                logflare :: undefinedc | pid(),
                config :: [term()]
               }).

init(Config) ->
    {ok, #state {
            id = proplists:get_value(id, Config, ?MODULE),
            level = lager_util:config_to_mask(
                      proplists:get_value(level, Config, debug)
                     ),
            config = Config
           }}.

handle_call(get_loglevel, #state{level=Level} = State) ->
    {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
    try lager_util:config_to_mask(Level) of
        Levels ->
            {ok, ok, State#state{level=Levels}}
    catch
        _:_ ->
            {ok, {error, bad_log_level}, State}
    end;
handle_call(_Request, State) ->
    {ok, ok, State}.


%% We delay initializing logflare as it depends on Gun running
%% and lager starts earlier than Gun, which results in not being
%% able to use Gun to open a connection from Logflare.
handle_event(E, #state{ logflare = undefined, config = Config } = State) ->
    % Ensure everything is ready
    application:ensure_all_started(logflare),
    case logflare:start_link(Config) of
        {ok, Pid} ->
            handle_event(E, State#state { logflare = Pid });
        {error, Reason} ->
            {stop, Reason}
    end;

handle_event({log, Message},
             #state{id = ID, level = L, logflare = Logflare} = State) ->
    case lager_util:is_loggable(Message, L, ID) of
        true ->
            Msg = #{ 
                     <<"message">> => iolist_to_binary(lager_msg:message(Message)),
                     <<"metadata">> => maps:from_list(lager_msg:metadata(Message))
                   },
            logflare:async(Logflare, Msg),
            {ok, State};
        false ->
            {ok, State}
    end;
handle_event(_Event, State) ->
    {ok, State}.

handle_info({'DOWN', _, process, Logflare, _}, #state{logflare=Logflare}) ->
    remove_handler;
handle_info(_Info, State) ->
    {ok, State}.

terminate(remove_handler, _State=#state{id=ID}) ->
    %% have to do this asynchronously because we're in the event handler
    spawn(fun() -> lager:clear_trace_by_destination(ID) end),
    ok;
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
