-record(fake_user, {
    id :: binary(),
    host :: binary(),
    data = #{} :: map()
}).

-define(DEFAULT_BACKEND, mnesia).
