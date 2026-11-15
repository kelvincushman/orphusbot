-- The last card a stuck teammate's asker was told about, so the checker says
-- so once per card (DESIGN §5.3).
alter table ticket add column asker_told text;
