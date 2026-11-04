"""Generate minimal EPUB2/3 and deliberately malformed ZIPs; no network or copyrighted content."""
from pathlib import Path
import zipfile, sys, hashlib, uuid
root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
container = '''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="BOOK/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'''
package = '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Offline Test Book</dc:title><dc:creator>Nomad Tests</dc:creator><dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier></metadata><manifest><item id="one" href="chapter%20one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="chapter2.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="image" href="images/diagram.svg" media-type="image/svg+xml"/><item id="css" href="styles/book.css" media-type="text/css"/></manifest><spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine></package>'''
nav = '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter%20one.xhtml">First chapter</a></li><li><a href="chapter2.xhtml#second">Second chapter</a></li></ol></nav></body></html>'''
ncx = '''<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint><navLabel><text>First chapter</text></navLabel><content src="chapter%20one.xhtml"/></navPoint><navPoint><navLabel><text>Second chapter</text></navLabel><content src="chapter2.xhtml#second"/></navPoint></navMap></ncx>'''
chapter = '''<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title><link href="styles/book.css" rel="stylesheet"/></head><body><h1>Offline knowledge</h1><p>Navigation by stars and a compass.</p><img src="images/diagram.svg" alt="A simple diagram"/><a href="chapter2.xhtml#second">Continue</a></body></html>'''
files = {'mimetype':'application/epub+zip','META-INF/container.xml':container,'BOOK/package.opf':package,'BOOK/nav.xhtml':nav,'BOOK/toc.ncx':ncx,'BOOK/chapter one.xhtml':chapter,'BOOK/chapter2.xhtml':chapter.replace('Offline knowledge','Second chapter'),'BOOK/images/diagram.svg':'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><circle cx="50" cy="50" r="40" fill="blue"/></svg>','BOOK/styles/book.css':'body { font-family: serif; }'}
def write(name, content):
    with zipfile.ZipFile(root/name,'w') as z:
        for key,value in content.items(): z.writestr(key,value,compress_type=zipfile.ZIP_STORED if key == 'mimetype' else zipfile.ZIP_DEFLATED)
write('valid.epub',files)
write('epub2.epub',{**files,'BOOK/package.opf':package.replace(' properties="nav"','').replace('version="3.0"','version="2.0"')})
write('unsafe.epub',{**files,'../../escape.txt':'unsafe'})
write('drm.epub',{**files,'META-INF/encryption.xml':'<encryption><EncryptedData><EncryptionMethod Algorithm="unsupported-drm"/><CipherData><CipherReference URI="BOOK/chapter2.xhtml"/></CipherData></EncryptedData></encryption>'})
write('entities.epub',{**files,'META-INF/container.xml':'<!DOCTYPE container [<!ENTITY injected "BAD">]>'+container.replace('<?xml version="1.0"?>','').replace('<rootfiles>','<rootfiles>&injected;')})
# A valid directory with a corrupt resource CRC, without changing compressed bytes.
corrupt = bytearray((root/'valid.epub').read_bytes()); position = 0
while True:
    position = corrupt.find(b'PK\x01\x02',position)
    if position < 0: raise RuntimeError('Central entry not found')
    length = int.from_bytes(corrupt[position+28:position+30],'little')
    name = corrupt[position+46:position+46+length]
    if name == b'BOOK/chapter2.xhtml': corrupt[position+16] ^= 1; break
    position += 4
(root/'crc.epub').write_bytes(corrupt)
(root/'truncated.epub').write_bytes(b'PK\x03\x04truncated')
print(root)

font = bytes(range(256)) * 10
identifier = 'urn:uuid:12345678-1234-1234-1234-123456789abc'
for name, algorithm, key, length in [
    ('idpf-font', 'http://www.idpf.org/2008/embedding', hashlib.sha1(identifier.encode()).digest(), 1040),
    ('adobe-font', 'http://ns.adobe.com/pdf/enc#RC', uuid.UUID(identifier.removeprefix('urn:uuid:')).bytes, 1024)
]:
    encoded = bytearray(font)
    for index in range(min(length,len(encoded))): encoded[index] ^= key[index % len(key)]
    encryption = f'<encryption><EncryptedData><EncryptionMethod Algorithm="{algorithm}"/><CipherData><CipherReference URI="BOOK/test.otf"/></CipherData></EncryptedData></encryption>'
    write(name+'.epub',{**files,'BOOK/test.otf':encoded,'META-INF/encryption.xml':encryption})
