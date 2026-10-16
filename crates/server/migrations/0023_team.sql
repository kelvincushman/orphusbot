-- Bots working as a team (DESIGN §5.3): a bot can hand a teammate a task with
-- `ask_bot`; it becomes a ticket, and the answer goes back to the asker.

-- The bot that asked for this ticket, if a bot did.
alter table ticket add column asked_by bigint references bot (id) on delete set null;
-- How many hand-offs deep this is; at most 3, so bots can't pass work round forever.
alter table ticket add column ask_depth integer not null default 0 check (ask_depth between 0 and 3);
