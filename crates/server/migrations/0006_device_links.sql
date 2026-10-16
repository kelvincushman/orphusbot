-- Linking a device that can't use passkeys (DESIGN §12, open question D8).
--
-- The device asks for a link and gets a secret device code (kept by the
-- device; only its hash is stored) and a short user code to show. The owner,
-- signed in with a passkey elsewhere, approves the user code. The device's
-- next poll gets a session of its own, tied to the approving passkey.

create table device_link (
    device_hash bytea primary key check (length(device_hash) = 32),
    user_code text not null unique check (user_code ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$'),
    -- What the device said it is (from its User-Agent), shown on the approve screen.
    label text not null check (length(label) between 1 and 120),
    -- Set when approved.
    passkey_id bigint references passkey (id) on delete cascade,
    expires_at timestamptz not null
);
