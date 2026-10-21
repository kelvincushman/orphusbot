-- What a bot may do with the owner's phone and social accounts through
-- ContentSwarm (DESIGN §11.6): nothing, queue drafts, or also use the phone.
alter table bot add column phone text not null default 'none' check (phone in ('none', 'draft', 'operate'));
