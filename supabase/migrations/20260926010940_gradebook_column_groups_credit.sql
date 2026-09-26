-- Credit corrections to the column groups the backfill (20260925182621) produced.
--
-- That backfill reproduces the legacy groupedColumns heuristic exactly, mistakes included.
-- This migration corrects three of those mistakes, each demonstrated in the course material,
-- and nothing else. Each policy below names the rows it touches; every other column keeps
-- the group the backfill gave it. The legacy "base" expression is evaluated here once, only to
-- recognise the runs the backfill produced; no function, trigger, or classifier is left behind.
--
-- Only gradebook_column_group_id is written on columns, and only group rows this migration
-- empties are deleted. Moves never leave a gradebook, so the composite FKs keep holding.
--
--   1. Positive-gap split repair. Deleting quiz-3 left a hole in sort_order, and the legacy
--      contiguity check turned one Quiz family into two groups with the same name. Two
--      consecutive runs (no column between them) with the same legacy base, whose boundary
--      sort_orders are both non-NULL and differ by more than one, become one group: the earlier
--      run's. Equal, duplicate or NULL boundaries, different bases, and runs with anything in
--      between are left alone.
--
--   2. Expectation summaries. meets-expectations, approaching-expectations and
--      does-not-meet-expectations are one concept (they summarise the same skills) that the
--      prefix rule scattered into three groups of one. In a gradebook holding all three, where
--      each is alone in its group, the three are consecutive, and they share one identical
--      non-empty gradebook_columns dependency set, they become one group named "Expectations"
--      (our name for it): meets-expectations' group, renamed. Columns that merely share that
--      dependency set (midterm-standing) or sit next to each other with shared dependencies
--      (labs-drop-lowest, total-labs) are not touched.
--
--   3. Two-token family outlier. assignment-lab-3 has three slug parts and lands in the Lab
--      family; assignment-lab has two and falls to the generic Assignment group. A column whose
--      slug is exactly assignment-X, alone in its group, joins the one adjacent group that is
--      an established family for X: at least two members, every one with base assignment-X
--      (so every slug starts assignment-X-), and nothing else in it. If no family, only one
--      child, a family on both sides, or a non-adjacent family, the column stays where it is,
--      as does an assignment-X already grouped with other two-part assignment columns.

DO $$
DECLARE
  merge record;
  trio record;
  outlier record;
  emptied bigint[] := '{}';
  moved integer;
  case1_moves integer := 0;
  case2_moves integer := 0;
  case3_moves integer := 0;
  null_members_before bigint;
  null_members_after bigint;
BEGIN
  SELECT count(*) INTO null_members_before FROM public.gradebook_columns WHERE gradebook_column_group_id IS NULL;

  -- 1. Positive-gap split repair. Repeats until no qualifying pair is left, so a family split by
  --    several gaps is merged into its first run.
  LOOP
    WITH cols AS (
      SELECT
        gc.id,
        gc.gradebook_id,
        gc.gradebook_column_group_id AS group_id,
        gc.sort_order,
        -- The legacy base, exactly as the backfill computed it.
        CASE
          WHEN split_part(gc.slug, '-', 1) = 'assignment'
            AND length(gc.slug) - length(replace(gc.slug, '-', '')) + 1 >= 3
            THEN 'assignment-' || split_part(gc.slug, '-', 2)
          ELSE coalesce(nullif(split_part(gc.slug, '-', 1), ''), 'other')
        END AS base,
        row_number() OVER (PARTITION BY gc.gradebook_id ORDER BY coalesce(gc.sort_order, 0), gc.id) AS pos,
        lag(gc.gradebook_column_group_id)
          OVER (PARTITION BY gc.gradebook_id ORDER BY coalesce(gc.sort_order, 0), gc.id) AS prev_group_id
      FROM public.gradebook_columns gc
    ),
    segmented AS (
      SELECT cols.*,
        sum(CASE WHEN group_id IS DISTINCT FROM prev_group_id THEN 1 ELSE 0 END)
          OVER (PARTITION BY gradebook_id ORDER BY pos) AS seg
      FROM cols
    ),
    segments AS (
      SELECT gradebook_id, seg, min(group_id) AS group_id, count(*) AS len,
        count(DISTINCT base) AS bases, min(base) AS base, min(pos) AS first_pos, max(pos) AS last_pos
      FROM segmented
      GROUP BY gradebook_id, seg
    ),
    group_sizes AS (
      SELECT gradebook_column_group_id AS group_id, count(*) AS members
      FROM public.gradebook_columns
      WHERE gradebook_column_group_id IS NOT NULL
      GROUP BY gradebook_column_group_id
    )
    SELECT a.group_id AS keep_group_id, b.group_id AS merge_group_id
    INTO merge
    FROM segments a
    JOIN segments b ON b.gradebook_id = a.gradebook_id AND b.seg = a.seg + 1
    -- Each run is a whole group: the group has no members outside this segment.
    JOIN group_sizes ga ON ga.group_id = a.group_id AND ga.members = a.len
    JOIN group_sizes gb ON gb.group_id = b.group_id AND gb.members = b.len
    JOIN segmented last_a ON last_a.gradebook_id = a.gradebook_id AND last_a.pos = a.last_pos
    JOIN segmented first_b ON first_b.gradebook_id = b.gradebook_id AND first_b.pos = b.first_pos
    WHERE a.group_id <> b.group_id
      AND a.bases = 1 AND b.bases = 1 AND a.base = b.base
      AND last_a.sort_order IS NOT NULL AND first_b.sort_order IS NOT NULL
      AND first_b.sort_order::bigint > last_a.sort_order::bigint + 1
    ORDER BY a.gradebook_id, a.first_pos
    LIMIT 1;
    EXIT WHEN NOT FOUND;

    UPDATE public.gradebook_columns
    SET gradebook_column_group_id = merge.keep_group_id
    WHERE gradebook_column_group_id = merge.merge_group_id;
    GET DIAGNOSTICS moved = ROW_COUNT;
    case1_moves := case1_moves + moved;
    DELETE FROM public.gradebook_column_groups WHERE id = merge.merge_group_id;
    emptied := emptied || merge.merge_group_id;
  END LOOP;

  -- 2. Expectation summaries.
  FOR trio IN
    WITH summaries AS (
      SELECT
        gc.id,
        gc.gradebook_id,
        gc.slug,
        gc.gradebook_column_group_id AS group_id,
        row_number() OVER (PARTITION BY gc.gradebook_id ORDER BY coalesce(gc.sort_order, 0), gc.id) AS pos,
        -- Dependency set, order-insensitive; NULL when missing or empty.
        (SELECT jsonb_agg(dep ORDER BY dep)
           FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(gc.dependencies -> 'gradebook_columns') = 'array'
               THEN gc.dependencies -> 'gradebook_columns' ELSE '[]'::jsonb END) AS dep) AS depends_on
      FROM public.gradebook_columns gc
    ),
    group_sizes AS (
      SELECT gradebook_column_group_id AS group_id, count(*) AS members
      FROM public.gradebook_columns
      WHERE gradebook_column_group_id IS NOT NULL
      GROUP BY gradebook_column_group_id
    )
    SELECT
      s.gradebook_id,
      max(s.group_id) FILTER (WHERE s.slug = 'meets-expectations') AS meets_group_id,
      max(s.id) FILTER (WHERE s.slug = 'approaching-expectations') AS approaching_id,
      max(s.group_id) FILTER (WHERE s.slug = 'approaching-expectations') AS approaching_group_id,
      max(s.id) FILTER (WHERE s.slug = 'does-not-meet-expectations') AS does_id,
      max(s.group_id) FILTER (WHERE s.slug = 'does-not-meet-expectations') AS does_group_id
    FROM summaries s
    LEFT JOIN group_sizes g ON g.group_id = s.group_id
    WHERE s.slug IN ('meets-expectations', 'approaching-expectations', 'does-not-meet-expectations')
    GROUP BY s.gradebook_id
    HAVING count(*) = 3
      AND bool_and(s.group_id IS NOT NULL)    -- each is grouped at all
      AND bool_and(g.members = 1)             -- and alone in its group
      AND count(DISTINCT s.group_id) = 3
      AND max(s.pos) - min(s.pos) = 2         -- consecutive in display order
      AND bool_and(s.depends_on IS NOT NULL)  -- non-empty dependency sets
      AND count(DISTINCT s.depends_on) = 1    -- all identical
  LOOP
    UPDATE public.gradebook_column_groups SET name = 'Expectations' WHERE id = trio.meets_group_id;
    UPDATE public.gradebook_columns
    SET gradebook_column_group_id = trio.meets_group_id
    WHERE id IN (trio.approaching_id, trio.does_id);
    GET DIAGNOSTICS moved = ROW_COUNT;
    case2_moves := case2_moves + moved;
    DELETE FROM public.gradebook_column_groups WHERE id IN (trio.approaching_group_id, trio.does_group_id);
    emptied := emptied || trio.approaching_group_id || trio.does_group_id;
  END LOOP;

  -- 3. Two-token family outlier. Runs after case 1, so a family it merged counts as one.
  LOOP
    WITH cols AS (
      SELECT
        gc.id,
        gc.gradebook_id,
        gc.slug,
        gc.gradebook_column_group_id AS group_id,
        length(gc.slug) - length(replace(gc.slug, '-', '')) + 1 AS parts,
        -- The legacy base, exactly as the backfill computed it.
        CASE
          WHEN split_part(gc.slug, '-', 1) = 'assignment'
            AND length(gc.slug) - length(replace(gc.slug, '-', '')) + 1 >= 3
            THEN 'assignment-' || split_part(gc.slug, '-', 2)
          ELSE coalesce(nullif(split_part(gc.slug, '-', 1), ''), 'other')
        END AS base,
        row_number() OVER (PARTITION BY gc.gradebook_id ORDER BY coalesce(gc.sort_order, 0), gc.id) AS pos,
        lag(gc.gradebook_column_group_id)
          OVER (PARTITION BY gc.gradebook_id ORDER BY coalesce(gc.sort_order, 0), gc.id) AS prev_group_id
      FROM public.gradebook_columns gc
    ),
    segmented AS (
      SELECT cols.*,
        sum(CASE WHEN group_id IS DISTINCT FROM prev_group_id THEN 1 ELSE 0 END)
          OVER (PARTITION BY gradebook_id ORDER BY pos) AS seg
      FROM cols
    ),
    segments AS (
      SELECT gradebook_id, seg, min(group_id) AS group_id, count(*) AS len,
        count(DISTINCT base) AS bases, min(base) AS base, min(pos) AS first_pos, max(pos) AS last_pos
      FROM segmented
      GROUP BY gradebook_id, seg
    ),
    group_sizes AS (
      SELECT gradebook_column_group_id AS group_id, count(*) AS members
      FROM public.gradebook_columns
      WHERE gradebook_column_group_id IS NOT NULL
      GROUP BY gradebook_column_group_id
    ),
    candidates AS (
      SELECT o.id AS column_id, o.group_id AS outlier_group_id, f.group_id AS family_group_id
      FROM segmented o
      JOIN group_sizes og ON og.group_id = o.group_id AND og.members = 1
      JOIN segments f ON f.gradebook_id = o.gradebook_id
        AND (f.first_pos = o.pos + 1 OR f.last_pos = o.pos - 1)   -- immediately after or before
      JOIN group_sizes fg ON fg.group_id = f.group_id AND fg.members = f.len  -- the family is a whole group
      WHERE split_part(o.slug, '-', 1) = 'assignment'
        AND o.parts = 2
        AND split_part(o.slug, '-', 2) <> ''
        AND f.group_id <> o.group_id
        AND f.len >= 2
        AND f.bases = 1
        AND f.base = o.slug                                        -- family base is exactly assignment-X
        AND NOT EXISTS (
          SELECT 1 FROM public.gradebook_columns m
          WHERE m.gradebook_column_group_id = f.group_id
            AND left(m.slug, length(o.slug) + 1) <> o.slug || '-')
    )
    SELECT column_id, outlier_group_id, min(family_group_id) AS family_group_id
    INTO outlier
    FROM candidates
    GROUP BY column_id, outlier_group_id
    HAVING count(*) = 1                                              -- exactly one qualifying family
    ORDER BY column_id
    LIMIT 1;
    EXIT WHEN NOT FOUND;

    UPDATE public.gradebook_columns
    SET gradebook_column_group_id = outlier.family_group_id
    WHERE id = outlier.column_id;
    GET DIAGNOSTICS moved = ROW_COUNT;
    case3_moves := case3_moves + moved;
    DELETE FROM public.gradebook_column_groups WHERE id = outlier.outlier_group_id;
    emptied := emptied || outlier.outlier_group_id;
  END LOOP;

  -- Post-conditions: membership was only moved, never cleared, and every group this migration
  -- emptied is gone.
  SELECT count(*) INTO null_members_after FROM public.gradebook_columns WHERE gradebook_column_group_id IS NULL;
  IF null_members_after <> null_members_before THEN
    RAISE EXCEPTION 'credit correction changed the number of ungrouped columns (% -> %)', null_members_before, null_members_after;
  END IF;
  IF EXISTS (SELECT 1 FROM public.gradebook_column_groups WHERE id = ANY (emptied)) THEN
    RAISE EXCEPTION 'credit correction left behind a group it emptied';
  END IF;

  RAISE NOTICE 'column group credit corrections: % gap-split, % expectation-summary, % family-outlier column moves; % emptied groups removed',
    case1_moves, case2_moves, case3_moves, coalesce(array_length(emptied, 1), 0);
END $$;
