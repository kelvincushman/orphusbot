-- Mission notes (DESIGN §5.5, D-065): what each mission run ended with, and the
-- chief's progress lines, searchable, so the everyday team can follow missions.
-- Whether a note is private is read from its mission, so marking a mission
-- private later hides its old notes too.
create table note (
    id bigint generated always as identity primary key,
    mission_id bigint not null references mission (id) on delete cascade,
    bot text not null,
    text text not null check (length(text) between 1 and 4000),
    created_at timestamptz not null default now(),
    search tsvector generated always as (to_tsvector('english', text)) stored
);

create index note_search on note using gin (search);
create index note_mission on note (mission_id, id);
