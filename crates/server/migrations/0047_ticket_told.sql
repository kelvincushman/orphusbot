-- Which stuck card each recipient (the asker, the Orchestrator) has been told
-- about, so the checker tells each once per card and tries again when a
-- message didn't get through (DESIGN §5.3). Replaces `ticket.asker_told`,
-- which was set for both before either message was sent.
create table ticket_told (
    ticket_id bigint not null references ticket (id) on delete cascade,
    -- The bot's slug.
    recipient text not null,
    card text not null,
    delivered boolean not null default false,
    claimed_at timestamptz not null default now(),
    primary key (ticket_id, recipient)
);

insert into ticket_told (ticket_id, recipient, card, delivered)
select t.id, r.slug, t.asker_told, true
from ticket t
join bot a on a.id = t.asked_by
cross join lateral (select a.slug union select 'orchestrator') r
where t.asker_told is not null;

alter table ticket drop column asker_told;
