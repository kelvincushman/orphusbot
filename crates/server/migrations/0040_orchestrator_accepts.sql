-- The Orchestrator may accept a teammate's safe card (D-062), and the record
-- says so: it never counts as the owner's decision.
alter table effect drop constraint effect_decided_by_check;
alter table effect add constraint effect_decided_by_check
    check (decided_by in ('rule', 'ledger', 'owner', 'system1', 'orchestrator'));
