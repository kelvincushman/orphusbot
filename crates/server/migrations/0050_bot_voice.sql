-- Which of xAI's voices speaks for a bot on a call (DESIGN §12.8, D-074).
-- Null means the server's default (`ORPHUSBOT_XAI_VOICE`, else eve).
alter table bot add column voice text
    check (voice in ('ara', 'eve', 'leo', 'rex', 'sal'));
