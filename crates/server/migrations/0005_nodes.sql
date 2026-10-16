-- Enrolled nodes (DESIGN §4.1).
--
-- A node proves who it is by signing a one-time server nonce with its Ed25519
-- key. It gets onto this list with an enrolment code the owner creates while
-- signed in; codes last ten minutes, work once and are stored hashed.

create table node (
    id bigint generated always as identity primary key,
    name text not null unique check (name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'),
    public_key bytea not null unique check (length(public_key) = 32),
    created_at timestamptz not null default now(),
    last_seen_at timestamptz
);

create table enrolment_code (
    code_hash bytea primary key check (length(code_hash) = 32),
    expires_at timestamptz not null
);
