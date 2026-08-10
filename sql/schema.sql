
-- ============================================================================
-- Master tables
-- ============================================================================

CREATE TABLE municipality (
    ine_code     char(5) PRIMARY KEY,
    name         text NOT NULL,
    surface_km2  numeric(8,2) NOT NULL
);

CREATE TABLE crime_type_mun (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    all_years  boolean NOT NULL,
    violence   text
);

CREATE TABLE crime_type_reg (
    code         text PRIMARY KEY,
    name_en      text NOT NULL,
    level        smallint NOT NULL,
    parent_code  text REFERENCES crime_type_reg (code),
    violence     text
);

-- ============================================================================
-- Municipal data
-- ============================================================================

CREATE TABLE mun_population (
    ine_code  char(5) REFERENCES municipality (ine_code),
    year      smallint,
    sex       char(1),
    municipality_population     integer,

    PRIMARY KEY (ine_code, year, sex)
);


CREATE TABLE mun_crime (
    ine_code        char(5) REFERENCES municipality (ine_code),
    year            smallint,
    crime_code      text REFERENCES crime_type_mun (code),
    crime_count     integer,

    PRIMARY KEY (ine_code, year, crime_code)
);


-- ============================================================================
-- Regional data (whole Community of Madrid)
-- ============================================================================

CREATE TABLE reg_crime (
    year        smallint,
    crime_code  text REFERENCES crime_type_mun (code),
    value       integer,
    PRIMARY KEY (year, crime_code)
);

CREATE TABLE reg_offences (
    year        smallint,
    crime_code  text REFERENCES crime_type_reg (code),
    recorded    integer,
    cleared     integer,

    PRIMARY KEY (year, crime_code)
);

CREATE TABLE reg_victims (
    year            smallint,
    crime_code      text REFERENCES crime_type_reg (code),
    age             text,
    sex             char(1),
    victims_count   integer,

    PRIMARY KEY (year, crime_code, age, sex)
);

CREATE TABLE reg_offenders (
    year                smallint,
    crime_code          text REFERENCES crime_type_reg (code),
    age                 text,
    sex                 char(1),
    offenders_count     integer,

    PRIMARY KEY (year, crime_code, age, sex)
);
