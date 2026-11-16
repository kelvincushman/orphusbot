-- A bot's own notes (DESIGN §5.6, D-071): short standing notes on how the
-- owner likes this bot to work, kept by the owner in the app and by the bot
-- with its notes tools, and read into every run. In the bot's own row, so no
-- other bot can reach them. 16 KB at most; the version goes up with every
-- save, so a save made from an older copy is refused.
alter table bot
    add column notes text not null default '' check (octet_length(notes) <= 16384),
    add column notes_version bigint not null default 0;
