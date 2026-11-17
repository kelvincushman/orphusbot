-- The Health screen (DESIGN §12.8): the latest result of each check of an
-- outside service the bots rely on (Google, nodes, xAI, model servers, ntfy,
-- disk). One row per check, overwritten each time it runs. `since` is when it
-- started failing and is kept while it stays failing, so a push goes out once
-- when a check turns red and once when it turns green again.
create table health_check (
    -- `google`, `node:<name>`, `xai`, `disk`, …
    name text primary key,
    -- What the owner sees, such as "Google".
    label text not null,
    ok boolean not null,
    -- Plain words: what is wrong and how to fix it. Only while failing.
    problem text,
    fix text,
    since timestamptz,
    checked_at timestamptz not null default now(),
    check (ok = (problem is null) and ok = (fix is null) and ok = (since is null))
);
