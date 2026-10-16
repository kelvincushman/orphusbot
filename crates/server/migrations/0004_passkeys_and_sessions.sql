-- Passkeys and sign-in sessions (DESIGN §12; PRD B-CLI-06).
--
-- OrphusBot has one owner. Their passkeys are stored as webauthn-rs
-- `Passkey` JSON. A session is a random token in an HttpOnly cookie; only its
-- SHA-256 hash is stored, so a database leak doesn't hand out sessions.

create table passkey (
    id bigint generated always as identity primary key,
    name text not null check (length(name) between 1 and 60),
    credential jsonb not null,
    created_at timestamptz not null default now(),
    last_used_at timestamptz
);

create table session (
    token_hash bytea primary key check (length(token_hash) = 32),
    -- Null for a setup session: signed in with the setup token to add the first passkey.
    -- Removing a passkey signs out everywhere it was used.
    passkey_id bigint references passkey (id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null
);

create index session_by_expiry on session (expires_at);
