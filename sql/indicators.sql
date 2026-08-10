-- ===========================================================================
-- 1. Shared helpers
-- ===========================================================================

DROP VIEW IF EXISTS v_reg_population CASCADE;
CREATE VIEW v_reg_population AS
SELECT
  year,
  sex,
  sum(municipality_population)::bigint AS population
FROM mun_population
GROUP BY year, sex;


DROP VIEW IF EXISTS v_mun_base CASCADE;
CREATE VIEW v_mun_base AS
SELECT
  mc.ine_code,
  mc.year,
  mc.crime_code,
  mc.crime_count,
  ct.violence,
  mp.municipality_population AS population,
  m.surface_km2
FROM mun_crime mc
JOIN crime_type_mun ct
  ON ct.code = mc.crime_code
  AND ct.all_years
JOIN municipality m
  ON m.ine_code = mc.ine_code
JOIN mun_population mp
  ON mp.ine_code = mc.ine_code
  AND mp.year = mc.year
  AND mp.sex = 'T';


-- ===========================================================================
-- 2. Crime Level: CL(i,t) = C(i,t) / D(i,t) * k where
--   C(i,t) = number of recorded offences
--   D(i,t) = population or surface area
--   k      = scaling factor (e.g. 1,000 or 100,000)
-- ===========================================================================

DROP TABLE IF EXISTS ind_crime_level;
CREATE TABLE ind_crime_level AS
WITH offence_counts AS (
  SELECT
    ine_code,
    year,
    crime_code,
    sum(crime_count) AS offences,
    max(population) AS population,
    max(surface_km2) AS surface_km2
  FROM v_mun_base
  GROUP BY ine_code, year, crime_code

  UNION ALL

  -- Sum of the eleven comparable concepts
  SELECT
    ine_code,
    year,
    'ALL_COMPARABLE',
    sum(crime_count),
    max(population),
    max(surface_km2)
  FROM v_mun_base
  GROUP BY ine_code, year
)
-- Offences per inhabitant
SELECT
  ine_code,
  year,
  crime_code,
  'population' AS denominator,
  offences::bigint AS offences,
  round(population::numeric, 2) AS denom_value,
  round(offences / population::numeric, 8) AS rate,
  round(offences / population::numeric * 1000, 4) AS rate_per_1000,
  round(offences / population::numeric * 100000, 4) AS rate_per_100000
FROM offence_counts
WHERE population > 0

UNION ALL

-- Offences per km2. The two scaled columns are undefined here on purpose.
SELECT
  ine_code,
  year,
  crime_code,
  'area' AS denominator,
  offences::bigint AS offences,
  round(surface_km2::numeric, 2) AS denom_value,
  round(offences / surface_km2::numeric, 8) AS rate,
  NULL::numeric AS rate_per_1000,
  NULL::numeric AS rate_per_100000
FROM offence_counts
WHERE surface_km2 > 0;

ALTER TABLE ind_crime_level ADD PRIMARY KEY (ine_code, year, crime_code, denominator);

-- ===========================================================================
-- 3. Police Performance
--
--   Clearance Rate: CR = S(c,t) / R(c,t)
--   Unsolved Crime Profile: UCP = max(R(c,t) - S(c,t), 0)
--   Unsolved Share in Level: USL = U(c,t) / Σ U(c',t)
--
--   where
--     S(c,t) = cleared offences
--     R(c,t) = recorded offences
--     U(c,t) = unsolved offences
--     c'     = all crime types in the same level as c
-- ===========================================================================

DROP TABLE IF EXISTS ind_police_performance;
CREATE TABLE ind_police_performance AS
WITH base AS (
  SELECT
    ro.year,
    ro.crime_code,
    ct.name_en,
    ct.level,
    ct.parent_code,
    ro.recorded,
    ro.cleared,
    greatest(ro.recorded - ro.cleared, 0) AS unsolved
  FROM reg_offences ro
  JOIN crime_type_reg ct
    ON ct.code = ro.crime_code
)
SELECT
  year,
  crime_code,
  name_en,
  level,
  parent_code,
  recorded,
  cleared,
  unsolved,
  round(cleared::numeric / nullif(recorded, 0), 6) AS clearance_rate,
  (cleared > recorded) AS clearance_above_one,
  round(unsolved::numeric / nullif(sum(unsolved) OVER (PARTITION BY year, level), 0), 6) AS unsolved_share_in_level
FROM base;

ALTER TABLE ind_police_performance ADD PRIMARY KEY (year, crime_code);


-- ===========================================================================
-- 4. Demographic Profile
--
--    Share: S = cases / total
--    Victimization Rate: VR = cases / population * 10000
-- ===========================================================================

DROP TABLE IF EXISTS ind_demographic_profile;
CREATE TABLE ind_demographic_profile AS
WITH stacked AS (
  SELECT
    'victims'::text AS measure,
    year,
    crime_code,
    age,
    sex,
    victims_count AS cases
  FROM reg_victims

  UNION ALL

  SELECT
    'offenders',
    year,
    crime_code,
    age,
    sex,
    offenders_count AS cases
  FROM reg_offenders
),
-- Total over both age and sex, used as the denominator of the share.
totals AS (
  SELECT
    measure,
    year,
    crime_code,
    sum(cases) AS total
  FROM stacked
  GROUP BY measure, year, crime_code
),

with_all_ages AS (
    SELECT
      *
    FROM stacked

    UNION ALL

    SELECT
      measure,
      year,
      crime_code,
      'ALL',
      sex,
      sum(cases)
    FROM stacked
    GROUP BY measure, year, crime_code, sex
)
SELECT
  a.measure,
  a.year,
  a.crime_code,
  ct.name_en,
  ct.level,
  a.age,
  a.sex,
  a.cases,
  (a.age = 'ALL') AS is_age_total,
  (a.age IN ('14-17', '18-30', '31-40', '41-64', '65+')) AS comparable_band,
  round(a.cases::numeric / nullif(t.total, 0), 6) AS share,
  CASE 
    WHEN a.age = 'ALL' THEN round(a.cases::numeric / nullif(p.population, 0) * 10000, 4)
  END AS rate_per_10000
FROM with_all_ages a
JOIN totals t
  ON t.measure = a.measure
  AND t.year = a.year
  AND t.crime_code = a.crime_code
JOIN crime_type_reg ct
  ON ct.code = a.crime_code
LEFT JOIN v_reg_population p
  ON p.year = a.year
  AND p.sex = a.sex;

ALTER TABLE ind_demographic_profile ADD PRIMARY KEY (measure, year, crime_code, age, sex);


-- ===========================================================================
-- 5. Crime Structure
--
--    Violent Ratio: VR = V / N
--    Violent Share: VS = V / (V + N)
--    Unclassified Share: US = U / total
--    Shannon Entropy: SE = - Σ p_c ln p_c
--    Normalised Shannon Entropy: NSE = SE / ln(crime_types_count)
--
--    where
--      V = violent offences
--      N = non-violent offences
--      U = unclassified offences
--      p_c = proportion of offence type c in the total
-- ===========================================================================

DROP TABLE IF EXISTS ind_crime_structure;
CREATE TABLE ind_crime_structure AS
WITH shares AS (
  SELECT
    ine_code,
    year,
    crime_code,
    violence,
    crime_count,
    population,
    crime_count::numeric / nullif(sum(crime_count) OVER (PARTITION BY ine_code, year), 0) AS proportion
  FROM v_mun_base
),

agg AS (
  SELECT
    ine_code,
    year,
    max(population) AS population,
    sum(crime_count) AS total,
    -- coalesce because a filtered sum over an empty set is NULL, not zero.
    coalesce(sum(crime_count) FILTER (WHERE violence = 'violent'), 0)      AS violent,
    coalesce(sum(crime_count) FILTER (WHERE violence = 'non_violent'), 0)  AS non_violent,
    coalesce(sum(crime_count) FILTER (WHERE violence = 'unclassified'), 0) AS unclassified,
    count(*) FILTER (WHERE crime_count > 0) AS crime_types_count,
    -sum(CASE WHEN proportion > 0 THEN proportion * ln(proportion) ELSE 0 END) AS shannon
  FROM shares
  GROUP BY ine_code, year
)

SELECT
  ine_code,
  year,
  population,
  total,
  violent,
  non_violent,
  unclassified,
  crime_types_count,
  round(violent::numeric / nullif(non_violent, 0), 6) AS violent_ratio,
  round(violent::numeric / nullif(violent + non_violent, 0), 6) AS violent_share,
  round(unclassified::numeric / nullif(total, 0), 6) AS unclassified_share,
  round(shannon, 6) AS shannon,
  round(shannon / nullif(ln(nullif(crime_types_count, 1)::numeric), 0), 6) AS shannon_normalised
FROM agg;

ALTER TABLE ind_crime_structure ADD PRIMARY KEY (ine_code, year);


-- ===========================================================================
-- 6. Crime Specialisation: LQ(i,t,c) = (c_ict / c_it) / (c_ct / c_t) where
--   c_ict = offences of type c in municipality i and year t
--   c_it  = all offences in municipality i and year t
--   c_ct  = offences of type c across every published municipality in year t
--   c_t   = all offences across every published municipality in year t
-- ===========================================================================

DROP TABLE IF EXISTS ind_crime_specialisation;
CREATE TABLE ind_crime_specialisation AS
WITH municipal AS (
  SELECT
    ine_code,
    year,
    crime_code,
    crime_count,
    sum(crime_count) OVER (PARTITION BY ine_code, year) AS municipal_total
  FROM v_mun_base
),

reference AS (
  SELECT
    year,
    crime_code,
    sum(crime_count) AS reference_offences,
    sum(sum(crime_count)) OVER (PARTITION BY year) AS reference_total
  FROM v_mun_base
  GROUP BY year, crime_code
)

SELECT
  m.ine_code,
  m.year,
  m.crime_code,
  m.crime_count AS offences,
  m.municipal_total,
  round(m.crime_count::numeric / nullif(m.municipal_total, 0), 6) AS local_share,
  round(r.reference_offences::numeric / nullif(r.reference_total, 0), 6) AS reference_share,
  round((m.crime_count::numeric / nullif(m.municipal_total, 0)) / nullif(r.reference_offences::numeric / nullif(r.reference_total, 0), 0),6) AS location_quotient
FROM municipal m
JOIN reference r
  ON r.year = m.year
  AND r.crime_code = m.crime_code;

ALTER TABLE ind_crime_specialisation ADD PRIMARY KEY (ine_code, year, crime_code);