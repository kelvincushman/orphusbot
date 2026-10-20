-- A bot's face from the library (design/bot-avatar styles). Null keeps the
-- old behaviour: its own style if one has its slug, else the default.
alter table bot add column face text check (face is null or face ~ '^[a-z0-9][a-z0-9-]{0,39}$');
