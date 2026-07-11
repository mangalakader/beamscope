-module(mod_fake_backend).
-behaviour(gen_mod).

-include("fake_backend.hrl").

-export([start/2, stop/1, get_user/2, save_user/3]).

-define(BACKEND_MODULE(Host), gen_mod:get_module_opt(Host, ?MODULE, backend, mnesia)).

start(Host, Opts) ->
    gen_mod:start_backend_module(?MODULE, Opts, [get_user/2, save_user/3]),
    ok.

stop(_Host) ->
    ok.

-spec get_user(binary(), binary()) -> {ok, map()} | {error, not_found}.
get_user(Host, UserId) ->
    Backend = ?BACKEND_MODULE(Host),
    Backend:get_user(Host, UserId).

-spec save_user(binary(), binary(), map()) -> ok | {error, term()}.
save_user(Host, UserId, Data) ->
    Backend = ?BACKEND_MODULE(Host),
    Backend:save_user(Host, UserId, Data).
