-- Whether a bot may generate images and video through the node's media tool
-- (kie.ai, DESIGN §11.7). Generating spends the owner's credits.
alter table bot add column media boolean not null default false;
