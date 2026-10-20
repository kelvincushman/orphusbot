-- UnifiedPush endpoints (DESIGN §12): one per signed-in phone app, given to
-- the app by its distributor (the ntfy app) and posted to for every push.
-- The API takes only https; plain http is left for the tests.
create table push_endpoint (
    url text primary key check (url like 'http%' and length(url) <= 1000),
    created_at timestamptz not null default now()
);
