#!/usr/bin/env python3
"""Disposable 256 MiB sparse fixtures. Tests production course copying and ZIM streaming."""
from pathlib import Path
import hashlib, sqlite3, subprocess, tempfile
root = Path(__file__).resolve().parents[3]
app = root / 'ipad/App'
vendor = root / 'ipad/Vendor/CoreKiwix.xcframework/macos-arm64_x86_64'
size = 256 * 1024 * 1024
with tempfile.TemporaryDirectory(prefix='nomad-large-reader-') as directory:
    folder = Path(directory)
    md5, sha = hashlib.md5(), hashlib.sha256()
    block = bytes(1024 * 1024)
    for _ in range(size // len(block)): md5.update(block); sha.update(block)
    checksum = md5.hexdigest()
    export = folder / 'export'
    (export / 'databases').mkdir(parents=True)
    asset = export / 'storage' / checksum[0] / checksum[1] / (checksum + '.mp4')
    asset.parent.mkdir(parents=True)
    with asset.open('wb') as file: file.truncate(size)
    identity, topic, lesson = 'a' * 32, 'b' * 32, 'c' * 32
    with sqlite3.connect(export / 'databases' / (identity + '.sqlite3')) as db:
        db.executescript('''CREATE TABLE content_channelmetadata(id TEXT,name TEXT,description TEXT,author TEXT,version INTEGER,min_schema_version TEXT,root_id TEXT);
CREATE TABLE content_contentnode(id TEXT,parent_id TEXT,content_id TEXT,channel_id TEXT,title TEXT,description TEXT,kind TEXT,author TEXT,license_name TEXT,license_owner TEXT,license_description TEXT,sort_order REAL);
CREATE TABLE content_file(id TEXT,contentnode_id TEXT,local_file_id TEXT,preset TEXT,thumbnail INTEGER,supplementary INTEGER,priority INTEGER);
CREATE TABLE content_localfile(id TEXT,extension TEXT);''')
        db.execute('INSERT INTO content_channelmetadata VALUES(?,?,?,?,?,?,?)', (identity,'TEST memory fixture','','TEST',1,'6',topic))
        for node,parent,kind in [(topic,None,'topic'),(lesson,topic,'video')]:
            db.execute('INSERT INTO content_contentnode VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', (node,parent,node,identity,'TEST synthetic bytes','Not playable media; only importer copy/hash is tested',kind,'TEST','TEST','TEST','TEST',0))
        db.execute('INSERT INTO content_localfile VALUES(?,?)', (checksum,'mp4'))
        db.execute('INSERT INTO content_file VALUES(?,?,?,?,?,?,?)', ('d'*32,lesson,checksum,'video',0,0,0))
    writer, bridge, binary = folder/'make-zim', folder/'bridge.o', folder/'reader-tests'
    subprocess.run(['xcrun','clang++','-std=c++17','-I',str(vendor/'Headers'),str(Path(__file__).with_name('create-zim.cpp')),str(vendor/'merged.a'),'-o',str(writer)], check=True)
    subprocess.run([str(writer),str(asset),str(folder/'large.zim')], check=True)
    subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-I',str(vendor/'Headers'),'-c',str(app/'Library/NomadZIMArchive.mm'),'-o',str(bridge)], check=True)
    sources = [app/'Education/CourseModels.swift', app/'Education/CourseChannelImport.swift', app/'Library/ZIMSchemeHandler.swift', Path(__file__).with_name('main.swift')]
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-warn-concurrency','-module-cache-path','/tmp/nomad-large-reader-cache','-import-objc-header',str(app/'Library/NomadZIM-Bridging-Header.h'),*map(str,sources),str(bridge),str(vendor/'merged.a'),'-lc++','-lsqlite3','-framework','WebKit','-framework','AppKit','-o',str(binary)], check=True)
    for mode in ['course','zim']:
        subprocess.run([str(binary),mode,str(folder),str(size),sha.hexdigest()],check=True,timeout=90)
