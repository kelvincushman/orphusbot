-- Signing in to an MCP server with OAuth (DESIGN §11): the server registers
-- itself as a client, the owner signs in, and the tokens are kept as secrets.

-- {client_id, token_endpoint} once a sign-in has started.
alter table connection add column oauth jsonb;
alter table connection add column refresh_secret_id bigint references secret (id) on delete set null;
alter table connection add column token_expires_at timestamptz;

-- A sign-in in progress: the state the provider sends back and the PKCE verifier. 10 minutes.
create table oauth_flow (
    state text primary key check (length(state) between 20 and 100),
    connection_id bigint not null references connection (id) on delete cascade,
    verifier text not null check (length(verifier) between 43 and 128),
    created_at timestamptz not null default now()
);
