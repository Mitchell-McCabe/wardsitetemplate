"""Build the Leaders download for a ward that hosts the site at its domain root."""
import json
import re
import sys
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

if len(sys.argv) != 2 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}', sys.argv[1]):
    sys.exit("Pass only the site's lowercase HTTPS hostname, for example ward.example.org")
root = Path(__file__).resolve().parents[1]
source = root / 'extension'
version = json.loads((source / 'manifest.json').read_text())['version']
archive = root / 'downloads' / f'ward-sync-v{version}.zip'
with ZipFile(archive, 'w', ZIP_DEFLATED) as package:
    for path in sorted(source.rglob('*')):
        if path.is_file():
            data = path.read_bytes()
            if path.suffix in ('.js', '.txt', '.json'):
                data = data.replace(b'ward.example.invalid', sys.argv[1].encode('ascii'))
            package.writestr(str(path.relative_to(source)), data)
