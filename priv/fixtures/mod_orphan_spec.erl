-module(mod_orphan_spec).
-export([foo/0]).

-callback handle_event(term()) -> ok.

-spec unused_callback_spec(term()) -> ok.

foo() ->
    ok.

-spec truly_orphaned(term()) -> ok.
