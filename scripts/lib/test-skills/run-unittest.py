"""Run the unittest cases of one Python test file, loaded by its exact path.

    python3 run-unittest.py <path/to/test_file.py>

scripts/test-skills.sh runs this once per file that git selected. Loading by
path runs that file and no other: `unittest discover -p` would also run a file
of the same name in a subpackage, and it skips a name that is not a valid
module name, such as `test_multi-chain.py`. The file's directory goes first on
sys.path, so it imports its siblings as it does when it runs as a script.

Exit 0 when every case passed or was skipped, 1 when a case failed or errored,
and 5 when the file ran no case and recorded no skip, as `python3 -m unittest`
does from Python 3.12.
"""

import importlib.util
import os
import re
import sys
import unittest


def main(path):
    path = os.path.abspath(path)
    sys.path.insert(0, os.path.dirname(path))
    name = re.sub(r"\W", "_", os.path.splitext(os.path.basename(path))[0])
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except unittest.SkipTest as reason:
        # unittest discovery records a module that raises SkipTest on import
        # as one skip, not a failure.
        print(f"skipped {path}: {reason}")
        return 0
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    # A module or class that raises SkipTest runs no test but records a skip.
    if result.testsRun == 0 and not result.skipped:
        print(f"no test cases in {path}", file=sys.stderr)
        return 5
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: run-unittest.py <test file>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
