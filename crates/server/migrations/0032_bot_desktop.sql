-- Which desktop a bot's computer on a node runs (DESIGN §4.4): the default
-- Debian image or the Omarchy-style one (images/omarchy).
alter table bot add column desktop text not null default 'debian' check (desktop in ('debian', 'omarchy'));
