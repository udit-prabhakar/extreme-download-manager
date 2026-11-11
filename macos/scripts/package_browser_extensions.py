"""Build standalone unpacked extensions from shared source, without dependencies."""
from pathlib import Path
import shutil
import sys

source = Path(__file__).resolve().parent.parent / 'BrowserExtension'
destination = Path(sys.argv[1])
for browser in ('chromium', 'firefox'):
    folder = destination / browser
    folder.mkdir(parents=True, exist_ok=True)
    for name in ('core.js', 'background.js', 'popup.html', 'popup.js', 'popup.css'):
        shutil.copyfile(source / name, folder / name)
    shutil.copyfile(source / 'manifests' / f'{browser}.json', folder / 'manifest.json')
