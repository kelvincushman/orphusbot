-- MCP servers that run as a command on the node (DESIGN §11). A node runs one
-- only if its program is on that node's ORPHUSBOT_MCP_COMMANDS allow-list.

alter table connection alter column url drop not null;
alter table connection add column command text check (command ~ '^[A-Za-z0-9._/-]{1,100}$');
alter table connection add column args text[] not null default '{}' check (cardinality(args) <= 20);
-- The command reads its token from this variable (GITHUB_TOKEN, …).
alter table connection add column token_env text check (token_env ~ '^[A-Z_][A-Z0-9_]{0,63}$');
alter table connection add constraint connection_url_or_command check ((url is null) <> (command is null));
