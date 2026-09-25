-- Relational integrity for gradebook column groups.
--
-- The single-column FKs from 20260925031250 let a group pair a gradebook with a
-- different class, and let a column join a group from another gradebook. These
-- composite FKs make both states unrepresentable. They replace the weaker FKs under
-- the same names rather than sitting beside them. NULL membership stays valid
-- (MATCH SIMPLE), so columns that are not yet backfilled are unaffected.

-- Supporting keys for the composite FKs below. id is already unique; these only make
-- the (id, owner) pairs referenceable and add no new domain rule.
alter table "public"."gradebooks"
  add constraint "gradebooks_id_class_id_key"
  unique (id, class_id);

alter table "public"."gradebook_column_groups"
  add constraint "gradebook_column_groups_id_gradebook_id_key"
  unique (id, gradebook_id);

-- A group's class must be the class that owns its gradebook.
alter table "public"."gradebook_column_groups"
  drop constraint "gradebook_column_groups_gradebook_id_fkey";

alter table "public"."gradebook_column_groups"
  add constraint "gradebook_column_groups_gradebook_id_fkey"
  foreign key (gradebook_id, class_id)
  references "public"."gradebooks"(id, class_id)
  not valid;

alter table "public"."gradebook_column_groups"
  validate constraint "gradebook_column_groups_gradebook_id_fkey";

-- A column may only join a group in its own gradebook.
alter table "public"."gradebook_columns"
  drop constraint "gradebook_columns_gradebook_column_group_id_fkey";

alter table "public"."gradebook_columns"
  add constraint "gradebook_columns_gradebook_column_group_id_fkey"
  foreign key (gradebook_column_group_id, gradebook_id)
  references "public"."gradebook_column_groups"(id, gradebook_id)
  not valid;

alter table "public"."gradebook_columns"
  validate constraint "gradebook_columns_gradebook_column_group_id_fkey";
