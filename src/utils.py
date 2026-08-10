"""
Auxiliary functions used by the three notebooks.
"""

import re
import unicodedata
from pathlib import Path
import json
from rdflib import Literal, URIRef

import pandas as pd

MASTERS = Path(__file__).resolve().parent.parent / "data" / "masters"



def is_blank(value):
    """
    Returns true if a cell is empty ºor contains only whitespace
    """
    return pd.isna(value) or str(value).strip() == ""


def fold(text):
    """
    Strip accents, punctuation and upper case, so two spellings match
    """
    text = unicodedata.normalize("NFKD", str(text))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^A-Za-z0-9]+", " ", text).strip().upper()


def read_table(path, n_header=1):
    """
    Read a spreadsheet from and returns (header, data). `header` is a list of 
    `n_header` rows, with merged group labels filled across the columns they span. 
    `data` is a DataFrame whose columns are numbered from 0.
    """
    raw = pd.read_excel(path, header=None)

    if is_blank(raw.iloc[0, 1]):
        raise ValueError(
            f"{path}: the first row is not a header. Remove the title rows above the table and save the file again."
        )

    header = []
    for i in range(n_header):
        row = raw.iloc[i]
        if n_header == 2 and i == 0:
            row = row.ffill()
        header.append(row)

    data = raw.iloc[n_header:]
    data = data[~data[0].apply(is_blank)].reset_index(drop=True)
    return header, data



def to_number(x):
    """
    Convert a published cell to a number, or None. 
    Handles the thousands separators and the Spanish decimal comma. 
    """
    if x is None or isinstance(x, bool):
        return None
    if isinstance(x, (int, float)):
        return None if pd.isna(x) else float(x)

    s = str(x).strip()
    if s in ("", ".", "..", "-", "n/a"):
        return None
    s = s.replace("\xa0", "").replace(" ", "").replace(" ", "")
    if "," in s:
        s = s.replace(".", "").replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def clean_name(x):
    """
    Normalise municipality names
    """
    if x is None:
        return ""
    s = str(x).strip()
    s = re.sub(r"^\s*-?\s*munic[ií]p?[ií]?o\s+de\s+", "", s, flags=re.I)   # "-Municipio de "
    s = re.sub(r"^\d{5}\s+", "", s)                                        # "28079 "

    articles = r"El|La|Los|Las"
    m = re.match(rf"^(.*),\s*({articles})$", s, flags=re.I)                # "Acebeda, La"
    if not m:
        m = re.match(rf"^(.*?)\s*\(({articles})\)$", s, flags=re.I)        # "Rozas ... (Las)"
    if m:
        s = f"{m.group(2)} {m.group(1).strip()}"

    return fold(s)


def crime_types(scheme):
    """
    Returns a DataFrame with the crime type master table for a specific scheme
    """
    return pd.read_csv(MASTERS / f"crime_type_{scheme}.csv")


def _crime_type_index(scheme):
    """
    Returns a dictionary mapping the Spanish headings to their English codes
    """
    df = crime_types(scheme)
    return {fold(r.source_name): r.code for r in df.itertuples()}


def clean_crime_type(label, scheme):
    """
    Returns the English code for a crime type, given its Spanish heading and the scheme
    """
    code = _crime_type_index(scheme).get(fold(label))
    if code is None:
        raise KeyError(
            f"Unknown crime type {str(label).strip()!r}. Add it as a new row in "
            f"masters/crime_type_{scheme}.csv with the code it corresponds to."
        )
    return code


def crime_type_table(scheme):
    """
    Returns the crime_type_table master table for a specific scheme
    """
    return (crime_types(scheme).drop(columns="source_name")
            .drop_duplicates("code").reset_index(drop=True))


def get_ine_code(x):
    """
    Returns the five digit INE code at the start of a label, or None
    """
    m = re.match(r"^\s*(\d{5})\s", str(x))
    return m.group(1) if m else None


def check(name, condition, detail=""):
    """
    Prints the result of a validation check and return True or False
    """
    print(f"[{'OK' if condition else 'FAIL'}] {name}" + (f" ({detail})" if detail else ""))
    return bool(condition)


def as_int(df, columns):
    """
    Stores whole numbers as integers so PostgreSQL can load them.
    """
    for c in columns:
        df[c] = df[c].round().astype("Int64")
    return df


def add_other(df, keys):
    parts = df[df.crime_code.isin(["OTHER_CONVENTIONAL", "CYBERCRIME"])]

    other = (
        parts.groupby(keys, as_index=False)
        .agg(
            crime_count=("crime_count", "sum"),
            n=("crime_code", "size")
        )
    )

    other = other[other.n == 2].drop(columns="n")
    other["crime_code"] = "OTHER"

    recomputed = set(map(tuple, other[keys].values))

    is_stale = (
        df.crime_code.eq("OTHER")
        & df[keys].apply(tuple, axis=1).isin(recomputed)
    )

    df = df[~is_stale]

    return pd.concat([df, other[df.columns]], ignore_index=True)


def q(sql, conn, params=None):
    """Run a query and return the result as a table."""
    return pd.read_sql_query(sql, conn, params=params)


def save_table(df, web, name):
    """
    Write a table as {"columns": [...], "rows": [[...], ...]}
    """
    payload = {
      "columns": list(df.columns),
      "rows": json.loads(df.to_json(orient="values", double_precision=6)),
    }
    path = web / f"{name}.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{path.name:34} {len(df):>6} rows {path.stat().st_size / 1024:>7.0f} KB")


def year_range(table, conn):
    row = q(f"SELECT min(year) AS a, max(year) AS b FROM {table}", conn).iloc[0]
    return [int(row["a"]), int(row["b"])]


def rows(sql, conn):
    """The rows of a query, as dictionaries, with a SQL NULL as None."""
    frame = q(sql, conn).astype(object)
    return frame.where(frame.notna(), None).to_dict("records")
