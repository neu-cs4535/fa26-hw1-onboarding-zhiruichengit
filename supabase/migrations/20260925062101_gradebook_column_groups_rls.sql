-- Row-level security for gradebook column groups.
--
-- Authorization keys on the group's own class_id. 20260925051247 guarantees it agrees
-- with the group's gradebook, so no lookup through gradebooks is needed.
--
-- Reads: any member of the class, the same audience as the gradebooks "class views"
-- policy. Group labels are course structure the student what-if view renders, so they
-- are not filtered by the visibility of member columns.
--
-- Writes: instructors only, matching "instructors CRUD" on gradebook_columns. They are
-- split per command so SELECT is governed by a single policy.
--
-- Predicates use the class_id IN (SELECT ... FROM user_privileges ...) form rather than
-- authorizeforclass*(class_id). The semantics are the same, and this form allows the
-- planner to hoist the membership lookup instead of invoking the STABLE helper once
-- per candidate row (see 20260825140000_audit_findings_2026_08.sql and
-- 20250917002948_optimize-submission-rls.sql).

alter table "public"."gradebook_column_groups" enable row level security;

-- gradebook_columns and gradebooks grant nothing to anon; match them.
revoke all on table "public"."gradebook_column_groups" from "anon";

create policy "everyone in class can view"
  on "public"."gradebook_column_groups"
  as permissive
  for select
  to authenticated
  using (
    class_id in (
      select up.class_id
      from public.user_privileges up
      where up.user_id = auth.uid()
    )
  );

create policy "instructors insert"
  on "public"."gradebook_column_groups"
  as permissive
  for insert
  to authenticated
  with check (
    class_id in (
      select up.class_id
      from public.user_privileges up
      where up.user_id = auth.uid()
        and up.role = 'instructor'
    )
  );

-- USING guards the existing row, WITH CHECK the resulting one, so an instructor cannot
-- move a group into a class they do not teach.
create policy "instructors update"
  on "public"."gradebook_column_groups"
  as permissive
  for update
  to authenticated
  using (
    class_id in (
      select up.class_id
      from public.user_privileges up
      where up.user_id = auth.uid()
        and up.role = 'instructor'
    )
  )
  with check (
    class_id in (
      select up.class_id
      from public.user_privileges up
      where up.user_id = auth.uid()
        and up.role = 'instructor'
    )
  );

create policy "instructors delete"
  on "public"."gradebook_column_groups"
  as permissive
  for delete
  to authenticated
  using (
    class_id in (
      select up.class_id
      from public.user_privileges up
      where up.user_id = auth.uid()
        and up.role = 'instructor'
    )
  );

-- Group reads are class-scoped, and every policy above filters on class_id.
create index "idx_gradebook_column_groups_class_id"
  on "public"."gradebook_column_groups" using btree (class_id);
