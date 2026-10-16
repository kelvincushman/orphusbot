-- Fleets the owner set up in OrphusBot (DESIGN §11.2): Orphus fleet blueprints,
-- written into every bot's work folder before a run so `/fleet <name>` finds them.
create table fleet (
    name text primary key check (name ~ '^[a-z0-9][a-z0-9_-]{0,47}$'),
    yaml text not null check (length(yaml) between 1 and 65536),
    updated_at timestamptz not null default now()
);
