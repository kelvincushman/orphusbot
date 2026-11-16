-- Whether a bot may research X through the server's `x_search` tool (DESIGN
-- §11.10). The query goes to xAI and each search costs money, so it is off
-- until the owner switches it on.
alter table bot add column x_search boolean not null default false;

-- How many X searches the server has made each day (UTC), across all bots, for
-- the daily cap (`ORPHUSBOT_X_SEARCH_PER_DAY`). In the database so a restart
-- doesn't reset the count.
create table x_search_day (
    day date primary key,
    searches integer not null check (searches > 0)
);
