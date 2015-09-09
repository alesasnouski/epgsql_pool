-module(epgsql_pool).

-export([start/3, stop/1,
         query/2, query/3, query/4,
         transaction/2
        ]).

-include("epgsql_pool.hrl").

-type(pool_name() :: binary() | string() | atom()).
-export_type([pool_name/0]).


%% Module API

-spec start(pool_name(), integer(), integer()) -> {ok, pid()} | {error, term()}.
start(PoolName0, InitCount, MaxCount) ->
    PoolName = epgsql_pool_utils:pool_name_to_atom(PoolName0),
    PoolConfig = [
                  {name, PoolName},
                  {init_count, InitCount},
                  {max_count, MaxCount},
                  {start_mfa, {epgsql_pool_worker, start_link, [PoolName]}}
                 ],
    pooler:new_pool(PoolConfig).


-spec stop(pool_name()) -> ok | {error, term()}.
stop(PoolName) ->
    pooler:rm_pool(epgsql_pool_utils:pool_name_to_atom(PoolName)).


-spec query(pool_name() | pid(), epgsql:sql_query()) -> epgsql:reply().
query(PoolNameOrWorker, Stmt) ->
    query(PoolNameOrWorker, Stmt, [], []).


-spec query(pool_name() | pid(), epgsql:sql_query(), [epgsql:bind_param()]) -> epgsql:reply().
query(PoolNameOrWorker, Stmt, Params) ->
    query(PoolNameOrWorker, Stmt, Params, []).


-spec query(pool_name() | pid(), epgsql:sql_query(), [epgsql:bind_param()], [proplists:option()]) -> epgsql:reply().
query(Worker, Stmt, Params, Options) when is_pid(Worker) ->
    Timeout = case proplists:get_value(timeout, Options) of
                  undefined -> epgsql_pool_settings:get(query_timeout);
                  V -> V
              end,
    error_logger:info_msg("Worker:~p Stmt:~p Params:~p", [Worker, Stmt, Params]), %% TEMP
    %% TODO process timeout,
    %% try-catch
    %% send cancel
    %% log error
    %% reply to client with error
    %% reconnect
    %% return to pool
    Res = gen_server:call(Worker, {query, Stmt, Params}, Timeout),
    Res;

query(PoolName, Stmt, Params, Options) ->
    case get_worker(PoolName) of
        {ok, Worker} -> query(Worker, Stmt, Params, Options);
        {error, Reason} -> {error, Reason}
    end.


-spec transaction(pool_name(), fun()) -> epgsql:reply() | {error, term()}.
transaction(PoolName, Fun) ->
    case get_worker(PoolName) of
        {ok, Worker} ->
            try
                gen_server:call(Worker, {query, "BEGIN", []}),
                Result = Fun(Worker),
                gen_server:call(Worker, {query, "COMMIT", []}),
                Result
            catch
                Err:Reason ->
                    gen_server:call(Worker, {query, "ROLLBACK", []}),
                    erlang:raise(Err, Reason, erlang:get_stacktrace())
            after
                pooler:return_member(PoolName, Worker, ok)
            end;
        {error, Reason} -> {error, Reason}
    end.


get_worker(PoolName0) ->
    PoolName = epgsql_pool_utils:pool_name_to_atom(PoolName0),
    Timeout = epgsql_pool_settings:get(pooler_get_worker_timeout),
    case pooler:take_member(PoolName, Timeout) of
        Worker when is_pid(Worker) -> {ok, Worker};
        error_no_members ->
            PoolStats = pooler:pool_stats(PoolName),
            error_logger:error_msg("Pool ~p overload: ~p", [PoolName, PoolStats]),
            {error, pool_overload}
    end.
