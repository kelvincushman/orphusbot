-- Where a wearable's deliberate captures go (DESIGN §9.3.5): a task in the
-- Inbox, or an idea for the Ideas Room. The owner picks it in the app.
alter table device
    add column captures_to text not null default 'inbox' check (captures_to in ('inbox', 'room'));
