-- Backfill gradebook column groups from the grouping the instructor gradebook derives
-- at render time today (groupedColumns in
-- app/course/[course_id]/manage/gradebook/gradebookTable.tsx).
--
-- This is a one-time translation of that heuristic into rows. It reproduces the
-- heuristic exactly, mistakes included: the quiz family split by a sort_order gap stays
-- two groups both named "Quiz", "ai-usage-log-*" stays "Ai", and so on. Every run gets a
-- group, including runs of one column; the UI only hides the header for those.
--
-- The heuristic, and how each step is reproduced:
--
--   sort       columns are stable-sorted by `sort_order ?? 0`. The database has no record
--              of the order the client received tied rows in, so ties are broken by id.
--              This is a migration-only ordering policy for an underdetermined case
--              (e.g. A:5, B:5, C:6 of one prefix is {A},{B,C} in one tie order and
--              {B},{A,C} in the other), not a grouping fix.
--   base       slug.split("-"): "assignment-<parts[1]>" when parts[0] is "assignment" and
--              there are at least 3 parts, otherwise parts[0] || "other".
--   contiguity currentSortOrder = sort_order ?? 0, contiguous when
--              lastSortOrder === -1 || currentSortOrder === lastSortOrder + 1.
--              lastSortOrder starts at -1 as a "no previous column" sentinel, so a real
--              previous value of -1 also makes the next row contiguous whatever its value
--              (-1, -1, 0 of one prefix is one run). Negative values are kept, not clamped.
--   new run    first row of the gradebook, a different base, or not contiguous.
--   name       "other" -> "Other"; "assignment-<type>" -> <type> capitalized; otherwise
--              the base capitalized.
--
-- Nothing is left behind: no function, trigger, or temp table. Only
-- gradebook_column_group_id is written on gradebook_columns; the row triggers that fire on
-- that UPDATE (audit, broadcast, cache invalidation, updated_at) are expected, and grades
-- are not recalculated because score_expression is unchanged.

DO $$
DECLARE
  existing_groups bigint;
  existing_members bigint;
  run record;
  new_group_id bigint;
BEGIN
  -- Stop rather than guess if anything has already been grouped. Nothing writes groups
  -- before this migration, so any existing state is unexpected and needs a human decision.
  SELECT count(*) INTO existing_groups FROM public.gradebook_column_groups;
  SELECT count(*) INTO existing_members FROM public.gradebook_columns
  WHERE gradebook_column_group_id IS NOT NULL;
  IF existing_groups > 0 OR existing_members > 0 THEN
    RAISE EXCEPTION 'gradebook column group backfill expected no existing group state, found % group rows and % columns with a group',
      existing_groups, existing_members;
  END IF;

  FOR run IN
    WITH parsed AS (
      SELECT
        gc.id,
        gc.gradebook_id,
        g.class_id,
        -- Sort key: the client's comparator uses `sort_order ?? 0`.
        coalesce(gc.sort_order, 0) AS sort_key,
        -- Contiguity value: the client's `currentSortOrder = col.sort_order ?? 0`. A separate
        -- concept from the sort key even though the definitions coincide today. bigint so the
        -- `+ 1` below behaves like the JS number it mirrors instead of overflowing at 2^31 - 1.
        coalesce(gc.sort_order, 0)::bigint AS contig_value,
        CASE
          WHEN split_part(gc.slug, '-', 1) = 'assignment'
            AND length(gc.slug) - length(replace(gc.slug, '-', '')) + 1 >= 3
            THEN 'assignment-' || split_part(gc.slug, '-', 2)
          ELSE coalesce(nullif(split_part(gc.slug, '-', 1), ''), 'other')
        END AS base
      FROM public.gradebook_columns gc
      JOIN public.gradebooks g ON g.id = gc.gradebook_id
    ),
    ordered AS (
      SELECT
        parsed.*,
        row_number() OVER w AS rn,
        lag(base) OVER w AS prev_base,
        lag(contig_value) OVER w AS prev_contig
      FROM parsed
      WINDOW w AS (PARTITION BY gradebook_id ORDER BY sort_key, id)
    ),
    flagged AS (
      SELECT
        ordered.*,
        (rn = 1
          OR base <> prev_base
          OR NOT (prev_contig = -1 OR contig_value = prev_contig + 1)) AS starts_run
      FROM ordered
    ),
    numbered AS (
      SELECT
        flagged.*,
        sum(CASE WHEN starts_run THEN 1 ELSE 0 END)
          OVER (PARTITION BY gradebook_id ORDER BY sort_key, id) AS run_no
      FROM flagged
    )
    SELECT
      gradebook_id,
      class_id,
      run_no,
      base,
      array_agg(id ORDER BY sort_key, id) AS column_ids
    FROM numbered
    GROUP BY gradebook_id, class_id, run_no, base
    ORDER BY gradebook_id, run_no
  LOOP
    INSERT INTO public.gradebook_column_groups (class_id, gradebook_id, name)
    VALUES (
      run.class_id,
      run.gradebook_id,
      CASE
        WHEN run.base = 'other' THEN 'Other'
        WHEN run.base LIKE 'assignment-%' THEN
          upper(left(substr(run.base, 12), 1)) || substr(run.base, 13)
        ELSE upper(left(run.base, 1)) || substr(run.base, 2)
      END
    )
    RETURNING id INTO new_group_id;

    UPDATE public.gradebook_columns
    SET gradebook_column_group_id = new_group_id
    WHERE id = ANY (run.column_ids);
  END LOOP;
END $$;
