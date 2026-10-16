-- Connections and secrets (DESIGN §11, PRD B-INT-01/04): MCP servers the owner
-- adds, their tokens encrypted under a master key kept outside the database,
-- and which bots may use each one.

create table secret (
    id bigint generated always as identity primary key,
    -- AES-256-GCM: a fresh 12-byte nonce, the ciphertext and its 16-byte tag.
    nonce bytea not null check (length(nonce) = 12),
    ciphertext bytea not null,
    tag bytea not null check (length(tag) = 16),
    created_at timestamptz not null default now()
);

create table connection (
    id bigint generated always as identity primary key,
    -- Prefixes the server's tools (pa_mail_list); `mcp…` is avoided (DESIGN §11).
    name text not null unique check (name ~ '^[a-z][a-z0-9_]{0,23}$' and name !~ '^mcp'),
    url text not null check (url ~ '^https?://' and length(url) <= 500),
    secret_id bigint references secret (id) on delete set null,
    created_at timestamptz not null default now()
);

create table bot_connection (
    bot_id bigint not null references bot (id) on delete cascade,
    connection_id bigint not null references connection (id) on delete cascade,
    primary key (bot_id, connection_id)
);
