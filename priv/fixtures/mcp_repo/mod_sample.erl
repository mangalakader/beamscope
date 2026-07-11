-module(mod_sample).
-export([start/1, stop/1]).

start(Host) ->
    helper(Host).

stop(_Host) ->
    ok.

helper(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, backend, mnesia).
