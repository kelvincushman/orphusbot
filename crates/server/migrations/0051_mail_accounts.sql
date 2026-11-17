-- The Himalaya accounts on the server a bot may use through the server's
-- `mail` tool (DESIGN §11.11, D-075). Names only: the addresses and passwords
-- stay in the server user's Himalaya config. Empty, the default, means no mail.
-- The owner sets them in the app's bot Settings.
alter table bot add column mail_accounts text[] not null default '{}'
    check (
        cardinality(mail_accounts) <= 8
        and array_to_string(mail_accounts, ' ', '-') ~ '^([A-Za-z0-9][A-Za-z0-9_.-]{0,63}( |$))*$'
    );
