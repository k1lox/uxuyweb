"""Give Flutter's tree-shaken icon font a stable URL per set of glyphs."""
import hashlib
import json
import re
from pathlib import Path

assets = Path(__file__).resolve().parents[1] / 'frontend/web/build/web/assets'
manifest = assets / 'FontManifest.json'
families = json.loads(manifest.read_bytes())
fonts = [font for family in families if family['family'] == 'MaterialIcons'
         for font in family['fonts']]
if len(fonts) != 1:
    raise ValueError('Expected one MaterialIcons font in the Flutter manifest')
entry = fonts[0]
if not re.fullmatch(r'fonts/MaterialIcons-Regular(?:-[0-9a-f]{16})?\.otf', entry['asset']):
    raise ValueError('Unexpected MaterialIcons asset path')
original = assets / entry['asset']
digest = hashlib.sha256(original.read_bytes()).hexdigest()[:16]
versioned = original.with_name(f'MaterialIcons-Regular-{digest}.otf')
if original != versioned:
    original.replace(versioned)
    entry['asset'] = versioned.relative_to(assets).as_posix()
    manifest.write_text(json.dumps(families, ensure_ascii=False, separators=(',', ':')))
# Flutter can leave a previous build's generated font alongside the new one.
for file in versioned.parent.glob('MaterialIcons-Regular-*.otf'):
    if file != versioned and re.fullmatch(r'MaterialIcons-Regular-[0-9a-f]{16}\.otf', file.name):
        file.unlink()
