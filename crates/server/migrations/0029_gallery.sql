-- The Gallery (DESIGN §12.2): files the owner keeps for bots to use as context
-- or as material (reference images for new ones, video). The bytes live on disk,
-- named by their SHA-256, so the same file is kept once; only the details are here.
create table gallery_item (
    id bigint generated always as identity primary key,
    name text not null check (length(name) between 1 and 200),
    mime text not null,
    size bigint not null check (size > 0),
    sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
    tags text[] not null default '{}',
    description text not null default '' check (length(description) <= 2000),
    -- Bots this is standing context for (their slugs).
    pinned_for text[] not null default '{}',
    -- 'upload', or 'bot:<slug>' when a bot made it.
    source text not null default 'upload',
    created_at timestamptz not null default now()
);
create index gallery_item_newest on gallery_item (created_at desc);
