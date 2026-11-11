"""Check tracked repository content without printing matched secret values."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
listed = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True, capture_output=True)
paths = [Path(value.decode()) for value in listed.stdout.split(b'\0') if value]
forbidden_parts = {'.build', '.build-before-move', '.edm-data', '__pycache__', 'node_modules'}
patterns = {
    'GitHub access token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
}
problems = []
for relative in paths:
    if forbidden_parts.intersection(relative.parts) or relative.parts[:2] == ('macos', 'analysis') or 'build' in relative.parts:
        problems.append((relative, 'generated or private path tracked'))
    if relative.name.startswith('.env') and relative.name != '.env.example':
        problems.append((relative, 'local environment file tracked'))
    path = ROOT / relative
    if not path.is_file(): continue
    if path.stat().st_size > 2 * 1024 * 1024:
        problems.append((relative, 'unexpected large tracked file; review before publication'))
        continue
    content = path.read_bytes()
    for label, pattern in patterns.items():
        if pattern.search(content): problems.append((relative, f'possible {label}; value suppressed'))
if problems:
    for path, reason in problems: print(f'{path}: {reason}', file=sys.stderr)
    sys.exit(1)
print(f'Repository hygiene passed for {len(paths)} tracked files. This bounded scan is not a full secret audit.')
