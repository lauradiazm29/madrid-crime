# Crime in the Community of Madrid

Open data from the Ministry of the Interior, the INE and the IDEM, turned into a
normalised PostgreSQL database, a set of crime indicators, a web application and
a knowledge graph.

```
madrid-crime/
├── notebooks/
│   ├── 01_cleaning.ipynb
│   ├── 02_integration_and_augmentation.ipynb
│   ├── 03_validation.ipynb
│   ├── 04_indicators.ipynb
│   └── 05_publication.ipynb
├── src/
│   └── utils.py
├── sql/
│   ├── schema.sql
│   └── indicators.sql
├── data/
│   ├── raw/
│   │   └── boundaries/
│   ├── masters/
│   ├── clean/
│   └── db/
├── web/
│   ├── index.html
│   ├── style.css
│   ├── app.js
│   └── data/
├── rdf/ 
│   ├── madrid_crime.ttl
└── requirements.txt
```


## 1. Set it up

You need Python and PostgreSQL 13 or newer.

```
pip install -r requirements.txt
```


## 2. Run the notebooks

Open them in order and run all cells. The whole pipeline goes from the files in
`data/raw` to a published site and an RDF turtle file.

- **`01_cleaning.ipynb`** reads the sources in `data/raw` and writes a tidy CSV for
each into `data/clean/`.

    Only one manual step: some downloaded files have title rows above the table and notes
    underneath, those are deleted by hand before the notebook reads it.

- **`02_integration_and_augmentation.ipynb`** turns the cleaned files into the tables that
go into the database, in `data/db/`.

- **`03_validation.ipynb`** checks the results and validates the final tables.

- **`04_indicators.ipynb`** creates the database, loads it and builds the indicators.

- **`05_publication.ipynb`** writes: the JSON files
the web page loads, the municipal boundaries as GeoJSON and the whole database
as RDF Turtle.


## 3. What is in the database

9 tables, loaded from `data/db/`:

| Table | Columns |
| --- | --- |
| `municipality` | ine_code, name and surface_km2 |
| `crime_type_mun` | code, name_en, all_years, violence |
| `crime_type_reg` | code, name_en, level, parent_code, violence |
| `mun_population` | ine_code, year, sex, population |
| `mun_crime` | ine_code, year, crime_code, crime_count |
| `reg_crime` | year, crime_code, value |
| `reg_offences` | year, crime_code, recorded, cleared |
| `reg_victims` | year, crime_code, age, sex, count |
| `reg_offenders` | year, crime_code, age, sex, count |

Then four indicator tables, built by `sql/indicators.sql`:

| Table | What it holds |
| --- | --- |
| `ind_crime_level` | offences per municipality, divided by population and by area |
| `ind_police_performance` | recorded, cleared, unsolved, clearance rate |
| `ind_demographic_profile` | victims and arrested persons by age band and sex |
| `ind_crime_structure` | what the offence mix is made of |
| `ind_crime_specialisation`| crime specialisation by offence type using the location quotient    



### Two classifications that must never be joined

- `crime_type_mun`, 20 types, used by `mun_crime` and `reg_crime`. This is the
Balance de Criminalidad, the only source published by municipality.

- `crime_type_reg`, 44 types in a hierarchy, used by `reg_offences`, `reg_victims`
and `reg_offenders`. This is the Estadistica de Criminalidad, much more
detailed, but only for the whole region.


## 4. The four module indicators

- **A. Crime level:** offences divided by the
resident population or by the surface area of the municipality.

- **B. Police performance:** cleared over recorded,
plus the unsolved offences and how they are distributed inside one level of the
category tree.

- **C. Demographic profile:** victims and arrested or investigated persons by age
band and sex, as counts, as shares, and as a rate per ten thousand inhabitants
of the same sex.

- **D. Crime structure:** the shape of the offence mix, the
violent share, the share that cannot be classified, the Shannon entropy of
the mix, and crime specialisation by offence type using the location quotient.


## 5. Things to know about the data

- **The 2020 crime file is different.** It uses a shorter list of offence types: no
split between conventional crime and cybercrime, and one column called
`Resto de infracciones penales` instead of three separate ones.


- **Only 35 to 37 municipalities out of 179 appear in the crime data.** The
Ministry publishes municipal figures only for municipalities above roughly
twenty thousand inhabitants: 35 from 2019 to 2022, 36 in 2023 and 2024, 37 in 1.

- **An offence recorded one year can be cleared the next**, so the two columns cover 
the same period but not the same offences. 


## 6. Where the raw files come from

| File | Source | Covers |
| --- | --- | --- |
| `master_municipalities.csv` | IGN Nomenclator Geografico de Municipios | all Spain, filtered to province 28 |
| `population_municipalities.xlsx` | INE, official population figures | municipal, 2019 to 2025 |
| `crimes/crimes_YYYY.xlsx` | Ministry of the Interior, Balance de Criminalidad | municipal, 2019 to 2025 |
| `recorded_offences.xlsx`, `cleared_offences.xlsx` | Ministry of the Interior, Estadistica de Criminalidad | region, 2019 to 2024 |
| `victimizations/`, `arrested_and_investigated_persons/` | Ministry of the Interior, Estadistica de Criminalidad | region, 2019 to 2024 |
| `boundaries/IDEM_CM_UNID_ADMINPolygon.*` | IDEM, Comunidad de Madrid | municipal boundaries |


## 7. The knowledge graph

The last section of notebook 05 writes `rdf/madrid_crime.ttl`, every row of
every table as a thing with an address, and every foreign key as a link between
those things. This is what moves the project from three star open data, machine
readable and openly licensed, to four star, where every municipality, offence
type and observation has an identifier that can be looked up.