#!/usr/bin/env python3
"""Run native course-engine checks using disposable, explicitly test-only exports.

Optional --upstream-fixture PATH imports the unmodified fields from Kolibri's
content_import_test.json into its table layout; this is an upstream test fixture,
not a downloaded production course. The runner performs no network requests.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("--upstream-fixture", type=Path)
args = parser.parse_args()
app = Path(__file__).resolve().parents[1]

SCHEMA = """
CREATE TABLE content_channelmetadata(id TEXT PRIMARY KEY,name TEXT,description TEXT,author TEXT,version INTEGER,min_schema_version TEXT,root_id TEXT);
CREATE TABLE content_contentnode(id TEXT PRIMARY KEY,parent_id TEXT,content_id TEXT,channel_id TEXT,title TEXT,description TEXT,kind TEXT,author TEXT,license_name TEXT,license_owner TEXT,license_description TEXT,sort_order REAL);
CREATE TABLE content_file(id TEXT PRIMARY KEY,contentnode_id TEXT,local_file_id TEXT,preset TEXT,thumbnail INTEGER,supplementary INTEGER,priority INTEGER);
CREATE TABLE content_localfile(id TEXT PRIMARY KEY,extension TEXT);
CREATE TABLE content_assessmentmetadata(id TEXT PRIMARY KEY,contentnode_id TEXT,number_of_assessments INTEGER);
"""


def channel(folder, archive):
    (folder / "databases").mkdir(parents=True)
    (folder / "storage").mkdir()
    identity, root_id, node_id, content_id = "a" * 32, "b" * 32, "c" * 32, "d" * 32
    checksum = hashlib.md5(archive).hexdigest()
    resource = folder / "storage" / checksum[0] / checksum[1] / (checksum + ".html5")
    resource.parent.mkdir(parents=True)
    resource.write_bytes(archive)
    database = folder / "databases" / (identity + ".sqlite3")
    with sqlite3.connect(database) as db:
        db.executescript(SCHEMA)
        db.execute("INSERT INTO content_channelmetadata VALUES(?,?,?,?,?,?,?)", (identity, "TEST-ONLY course", "Synthetic validation fixture", "TEST-ONLY author", 1, "6", root_id))
        for node, parent, kind, title, order in [(root_id, None, "topic", "TEST-ONLY topic", 0), (node_id, root_id, "html5", "TEST-ONLY lesson", 1)]:
            db.execute("INSERT INTO content_contentnode VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (node, parent, content_id if parent else root_id, identity, title, "TEST-ONLY description", kind, "TEST-ONLY author", "TEST-ONLY license", "TEST-ONLY owner", "TEST-ONLY license terms", order))
        db.execute("INSERT INTO content_localfile VALUES(?,?)", (checksum, "html5"))
        db.execute("INSERT INTO content_file VALUES(?,?,?,?,?,?,?)", ("e" * 32, node_id, checksum, "html5_zip", 0, 0, 0))
    return database


with tempfile.TemporaryDirectory(prefix="nomad-course-engine-") as temporary:
    folder = Path(temporary)
    def zip_bytes(name, entries, method=zipfile.ZIP_DEFLATED):
        target = folder / (name + ".zip")
        with zipfile.ZipFile(target, "w", compression=method) as archive:
            for path, content in entries:
                archive.writestr(path, content)
        return target.read_bytes()

    html = b"<!doctype html><title>TEST-ONLY</title><p>Synthetic offline lesson fixture</p>"
    good_zip = zip_bytes("deflated", [("index.html", html), ("assets/test.txt", b"TEST-ONLY resource")])
    zip_bytes("stored", [("index.html", html)], zipfile.ZIP_STORED)
    zip_bytes("traversal", [("../outside.html", html)])
    zip_bytes("no-entry", [("readme.txt", b"TEST-ONLY")])
    zip_bytes("scorm", [("imsmanifest.xml", b'<manifest><resources><resource href="lesson/start.html"/></resources></manifest>'), ("lesson/start.html", html)])
    zip_bytes("external-scorm", [("imsmanifest.xml", b'<manifest><resources><resource href="https://example.invalid/remote.html"/></resources></manifest>')])
    with zipfile.ZipFile(folder / "symlink.zip", "w") as archive:
        info = zipfile.ZipInfo("index.html"); info.create_system = 3; info.external_attr = (0o120777 << 16)
        archive.writestr(info, "../../outside")
    corrupt = bytearray((folder / "stored.zip").read_bytes())
    start = 30 + struct.unpack_from("<H", corrupt, 26)[0] + struct.unpack_from("<H", corrupt, 28)[0]
    corrupt[start] ^= 1
    (folder / "bad-crc.zip").write_bytes(corrupt)
    (folder / "truncated.zip").write_bytes(good_zip[:-10])
    valid = folder / "valid-export"
    database = channel(valid, good_zip)
    exercise = folder / "exercise-export"
    shutil.copytree(valid, exercise)
    item = {"question": {"content": "TEST-ONLY exercise", "widgets": {}, "images": {}}, "hints": []}
    exercise_zip = zip_bytes("exercise", [("test-item.json", json.dumps(item))])
    checksum = hashlib.md5(exercise_zip).hexdigest()
    asset = exercise / "storage" / checksum[0] / checksum[1] / (checksum + ".perseus")
    asset.parent.mkdir(parents=True, exist_ok=True); asset.write_bytes(exercise_zip)
    with sqlite3.connect(exercise / "databases" / database.name) as db:
        db.executescript("ALTER TABLE content_contentnode ADD COLUMN lang_id TEXT; CREATE TABLE content_language(id TEXT PRIMARY KEY, lang_code TEXT, lang_subcode TEXT); ALTER TABLE content_assessmentmetadata ADD COLUMN assessment_item_ids TEXT; ALTER TABLE content_assessmentmetadata ADD COLUMN mastery_model TEXT; ALTER TABLE content_assessmentmetadata ADD COLUMN randomize INTEGER;")
        db.execute("INSERT INTO content_language VALUES('ar','ar','')")
        db.execute("UPDATE content_contentnode SET kind='exercise',lang_id='ar' WHERE kind='html5'")
        db.execute("UPDATE content_localfile SET id=?,extension='perseus'", (checksum,))
        db.execute("UPDATE content_file SET local_file_id=?,preset='exercise'", (checksum,))
        db.execute("INSERT INTO content_assessmentmetadata VALUES(?,?,?,?,?,?)", ("f" * 32, "c" * 32, 1, json.dumps(["test-item"]), '{"type":"m_of_n","m":3,"n":5}', 1))
    unsafe_items = folder / "unsafe-items"
    shutil.copytree(exercise, unsafe_items)
    with sqlite3.connect(unsafe_items / "databases" / database.name) as db:
        db.execute("UPDATE content_assessmentmetadata SET assessment_item_ids=?", (json.dumps(["../outside"]),))
    invalid = {
        "missing-schema": "DROP TABLE content_file;",
        "view-schema": "ALTER TABLE content_contentnode RENAME TO hidden_nodes; CREATE VIEW content_contentnode AS SELECT * FROM hidden_nodes;",
        "missing-parent": "UPDATE content_contentnode SET parent_id='ffffffffffffffffffffffffffffffff' WHERE kind='html5';",
        "cycle": "UPDATE content_contentnode SET parent_id=id,kind='topic' WHERE kind='html5';",
        "wrong-channel": "UPDATE content_channelmetadata SET id='ffffffffffffffffffffffffffffffff';",
        "missing-file-record": "DELETE FROM content_localfile;",
        "unsafe-checksum": "UPDATE content_localfile SET id='../unsafe'; UPDATE content_file SET local_file_id='../unsafe';",
    }
    for name, sql in invalid.items():
        destination = folder / name
        shutil.copytree(valid, destination)
        with sqlite3.connect(destination / "databases" / database.name) as db:
            db.executescript(sql)
    mismatch = folder / "checksum-mismatch"
    shutil.copytree(valid, mismatch)
    next((mismatch / "storage").rglob("*.html5")).write_bytes(b"TEST-ONLY corrupted resource")
    linked = folder / "symlink-resource"
    shutil.copytree(valid, linked)
    original = next((linked / "storage").rglob("*.html5"))
    original.unlink(); original.symlink_to(next((valid / "storage").rglob("*.html5")))
    missing = folder / "partial-export"
    shutil.copytree(valid, missing)
    next((missing / "storage").rglob("*.html5")).unlink()
    if args.upstream_fixture:
        records = json.loads(args.upstream_fixture.read_text())
        upstream = folder / "upstream-export"
        (upstream / "databases").mkdir(parents=True); (upstream / "storage").mkdir()
        metadata = next(row for row in records if row["model"] == "content.channelmetadata")
        with sqlite3.connect(upstream / "databases" / (metadata["pk"] + ".sqlite3")) as db:
            db.executescript(SCHEMA)
            for record in records:
                table = record["model"].replace(".", "_")
                columns = [row[1] for row in db.execute("PRAGMA table_info(" + table + ")")]
                if not columns: continue
                fields = record["fields"]
                values = []
                for column in columns:
                    value = record["pk"] if column == "id" else fields.get(column, fields.get(column.removesuffix("_id")))
                    if value is None and column in ("description", "author", "license_name", "license_owner", "license_description"): value = ""
                    values.append(value)
                db.execute("INSERT INTO " + table + " VALUES(" + ",".join("?" for _ in columns) + ")", values)
    binary = folder / "course-engine-tests"
    sources = [app / "Collections/LocalManifestFile.swift"] + [app / ("Education/" + name + ".swift") for name in ["CourseModels", "CourseZipArchive", "CourseChannelImport", "CourseStore", "CoursePerseusMessage", "CourseEngineTests"]]
    subprocess.run(["swiftc", "-swift-version", "5", "-D", "NOMAD_COURSE_ENGINE_TESTS", "-module-cache-path", str(Path(tempfile.gettempdir()) / "nomad-course-module-cache"), *map(str, sources), "-o", str(binary), "-lsqlite3", "-lz"], check=True)
    subprocess.run([str(binary), str(folder)], check=True)
