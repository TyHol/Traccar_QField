# Copyright (C) 2026 TyHol
# SPDX-License-Identifier: GPL-2.0-or-later

"""
Create traccar_template.gpkg — empty points and tracks layers with every field
the Traccar Live plugin fills. Add both layers to your QGIS project, then pick
them in the plugin under Settings → Layers.

Plain Python (sqlite3 only, no GDAL needed):
    python tools/make_template_gpkg.py [output.gpkg]
"""
import os
import sqlite3
import sys

WGS84_WKT = (
    'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,'
    'AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,'
    'AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,'
    'AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]]'
)

# (table, geometry type, has_z, has_m, description, fields)
LAYERS = [
    ("traccar_points", "POINT", 0, 0, "Traccar Live — saved positions", [
        ("device_id",  "INTEGER"),
        ("name",       "TEXT"),
        ("status",     "TEXT"),
        ("fix_time",   "DATETIME"),   # UTC
        ("fix_local",  "TEXT"),       # local wall-clock time on the saving device, e.g. "2026-10-09 09:15:30 BST"
        ("speed_kmh",  "REAL"),
        ("course",     "REAL"),
        ("altitude_m", "REAL"),
        ("accuracy_m", "REAL"),
        ("battery",    "REAL"),
        ("address",    "TEXT"),
        ("motion",     "TEXT"),
        ("fetched_at", "DATETIME"),
        ("tag",        "TEXT"),
    ]),
    ("traccar_tracks", "LINESTRING", 1, 1, "Traccar Live — saved tracks (Z = altitude, M = epoch seconds)", [
        ("device_id",   "INTEGER"),
        ("name",        "TEXT"),
        ("start_time",  "DATETIME"),  # UTC
        ("last_update", "DATETIME"),  # UTC
        ("start_local", "TEXT"),      # local wall-clock time as text
        ("last_local",  "TEXT"),
        ("from_time",   "DATETIME"),
        ("to_time",     "DATETIME"),
        ("n_points",    "INTEGER"),
        ("saved_at",    "DATETIME"),
        ("tag",         "TEXT"),
    ]),
]


def main(path):
    if os.path.exists(path):
        sys.exit(f"{path} already exists — not overwriting")
    con = sqlite3.connect(path)
    cur = con.cursor()
    cur.execute("PRAGMA application_id = 1196444487")  # 'GPKG'
    cur.execute("PRAGMA user_version = 10300")          # GeoPackage 1.3

    cur.execute("""CREATE TABLE gpkg_spatial_ref_sys (
        srs_name TEXT NOT NULL, srs_id INTEGER NOT NULL PRIMARY KEY,
        organization TEXT NOT NULL, organization_coordsys_id INTEGER NOT NULL,
        definition TEXT NOT NULL, description TEXT)""")
    cur.executemany("INSERT INTO gpkg_spatial_ref_sys VALUES (?,?,?,?,?,?)", [
        ("Undefined cartesian SRS", -1, "NONE", -1, "undefined", None),
        ("Undefined geographic SRS", 0, "NONE", 0, "undefined", None),
        ("WGS 84 geodetic", 4326, "EPSG", 4326, WGS84_WKT, None),
    ])
    cur.execute("""CREATE TABLE gpkg_contents (
        table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL,
        identifier TEXT UNIQUE, description TEXT DEFAULT '',
        last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
        min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE, srs_id INTEGER,
        CONSTRAINT fk_gc_r_srs_id FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id))""")
    cur.execute("""CREATE TABLE gpkg_geometry_columns (
        table_name TEXT NOT NULL, column_name TEXT NOT NULL,
        geometry_type_name TEXT NOT NULL, srs_id INTEGER NOT NULL,
        z TINYINT NOT NULL, m TINYINT NOT NULL,
        CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name),
        CONSTRAINT fk_gc_tn FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
        CONSTRAINT fk_gc_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys (srs_id))""")

    for table, gtype, z, m, desc, fields in LAYERS:
        cols = ",\n  ".join(f'"{n}" {t}' for n, t in fields)
        cur.execute(f'''CREATE TABLE "{table}" (
  "fid" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  "geom" {gtype},
  {cols})''')
        cur.execute("INSERT INTO gpkg_contents (table_name, data_type, identifier, description, srs_id) "
                    "VALUES (?, 'features', ?, ?, 4326)", (table, table, desc))
        cur.execute("INSERT INTO gpkg_geometry_columns VALUES (?, 'geom', ?, 4326, ?, ?)",
                    (table, gtype, z, m))

    con.commit()
    con.close()
    print(f"Created {path}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "traccar_template.gpkg")
