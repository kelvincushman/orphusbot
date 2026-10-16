-- Calibrations (DESIGN §7.5, M5.2): thresholds fitted to the owner's labels,
-- with how they did on the newest labels held out. At most one is active;
-- none active means the defaults.

create table decision_model (
    id bigint generated always as identity primary key,
    -- Per question, only those fitted: {"triage.bot": 0.82, "gate.verdict": 0.93}.
    thresholds jsonb not null check (jsonb_typeof(thresholds) = 'object'),
    -- Per question: labels used, held out, and before/after on the held-out ones.
    report jsonb not null,
    fitted_at timestamptz not null default now(),
    applied_at timestamptz,
    active boolean not null default false,
    -- Letting a tool call through never needs less than 0.9 (DESIGN §7.5).
    check (coalesce((thresholds ->> 'gate.verdict')::real, 1) >= 0.9),
    check (not active or applied_at is not null)
);

create unique index decision_model_one_active on decision_model (active) where active;
