import sys
from pathlib import Path

# SEE-1430b (M1): gqt repo-sync test suites migrated here; the repo-sync
# scripts under <root>/repo-sync/ import each other as top-level modules.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "repo-sync"))
