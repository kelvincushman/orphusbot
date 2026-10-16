-- Durable runs with leases and fences (DESIGN §3.2, §3.3).
--
-- A run is one attempt by the bot to answer the thread. While a node works
-- on it, the run holds a lease that the server renews; if the lease lapses
-- or the node drops, the run goes back to the queue. Every dispatch bumps
-- `fence`, and anything a node reports for an older fence is ignored.

create type run_status as enum ('queued', 'running', 'completed', 'failed', 'cancelled');

create table run (
    id bigint generated always as identity primary key,
    thread_id bigint not null references thread (id),
    prompt text not null check (length(prompt) > 0),
    status run_status not null default 'queued',
    fence bigint not null default 0 check (fence >= 0),
    node text,
    lease_expires_at timestamptz,
    attempts integer not null default 0 check (attempts >= 0),
    error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    -- A running run always has a holder and a lease; no other run has either.
    check ((status = 'running') = (node is not null and lease_expires_at is not null))
);

-- At most one run per thread is waiting or working. A second message either
-- joins the queued run's prompt or steers the running one.
create unique index run_one_active_per_thread on run (thread_id)
    where status in ('queued', 'running');

create index run_queued on run (created_at) where status = 'queued';
