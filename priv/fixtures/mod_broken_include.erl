-module(mod_broken_include).

-include("nonexistent_header_that_does_not_exist.hrl").

-export([works_fine/0, also_fine/1]).

works_fine() ->
    ok.

-spec also_fine(integer()) -> integer().
also_fine(X) ->
    X + 1.
