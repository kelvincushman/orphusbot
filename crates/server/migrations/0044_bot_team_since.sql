-- When a bot last became a team bot (DESIGN §11.9). Learned memory uses a bot's
-- reply as context only from after this, so a bot that was private doesn't
-- bring its private replies along. Bots that are team bots now count from here.
alter table bot add column team_since timestamptz not null default now();
