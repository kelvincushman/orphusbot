-- The wearable's device channel and duplex habitat (DESIGN §9.2, §9.3).

create table device (
    -- The app's own device id (its `devId`).
    id text primary key check (id ~ '^[A-Za-z0-9._:-]{1,64}$'),
    label text not null default '' check (length(label) <= 60),
    -- SHA-256 of the pairing token the app sends as X-Device-Token.
    token_hash bytea not null unique check (length(token_hash) = 32),
    hands_free boolean not null default false,
    created_at timestamptz not null default now(),
    last_seen_at timestamptz
);

-- One-time codes the owner makes while signed in; the app sends one as its
-- "bearer" when it registers, so the phone app needs no change.
create table device_pairing_code (
    code_hash bytea primary key check (length(code_hash) = 32),
    expires_at timestamptz not null
);

-- Every signal to the wrist (§9.3.1).
create table habitat_message (
    id bigint generated always as identity primary key,
    device_id text not null references device (id) on delete cascade,
    -- inform: no reply; ask: needs the wearer.
    kind text not null check (kind in ('inform', 'ask')),
    cue text not null,
    -- What it's about: run:<id>, dialog:<id>, ticket:<id>.
    subject text not null,
    -- For an ask: what a tap does (approve, start, ack, answer).
    tap text,
    -- queued (waiting its turn) → sent → delivered → answered / dismissed / expired / superseded.
    state text not null default 'queued'
        check (state in ('queued', 'sent', 'delivered', 'answered', 'dismissed', 'expired', 'superseded')),
    outcome text,
    escalate_after interval not null default interval '10 minutes',
    created_at timestamptz not null default now(),
    sent_at timestamptz,
    closed_at timestamptz
);

create index habitat_open on habitat_message (device_id, kind, state);

-- Runs started from a wearable button, so their cues go back to that wrist.
alter table run add column device_id text references device (id) on delete set null;
alter table ticket add column device_id text references device (id) on delete set null;
