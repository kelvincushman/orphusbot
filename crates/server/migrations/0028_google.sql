-- Google through the `gog` CLI on the node (DESIGN §11.5): what each bot may do.
-- none: no Google tool; read: look things up only; write: also create and
-- change (each change still asks the owner). Owner's choice: everyone reads, PA writes.
alter table bot add column google text not null default 'read'
    check (google in ('none', 'read', 'write'));
update bot set google = 'write' where slug = 'pa';
