-- Where each bot's computer (with its home volume) lives, so placement can send
-- its runs back there (DESIGN §6.3, rule "where its computer is").
create table bot_computer (
    bot text primary key check (length(bot) > 0),
    node text not null,
    updated_at timestamptz not null default now()
);
