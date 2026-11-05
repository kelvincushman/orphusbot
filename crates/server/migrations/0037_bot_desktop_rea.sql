-- A third desktop: the reverse-engineering computer (images/rea, D-058), with REA
-- and Ghidra inside and REA's MCP server run there by the node.
alter table bot drop constraint bot_desktop_check;
alter table bot add constraint bot_desktop_check check (desktop in ('debian', 'omarchy', 'rea'));
