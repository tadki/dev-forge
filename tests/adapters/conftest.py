import os
import sys

# Adapter tests import the package by name; adapters/ must be importable.
# tests/conftest.py already puts autopilots/ on sys.path — a flat module name
# would risk future collisions there, hence the package-style import.
adapters_dir = os.path.join(os.path.dirname(__file__), "..", "..", "adapters")
adapters_dir = os.path.abspath(adapters_dir)
if adapters_dir not in sys.path:
    sys.path.insert(0, adapters_dir)
