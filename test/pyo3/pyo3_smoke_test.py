import unittest

import pyo3_smoke


class Pyo3SmokeTest(unittest.TestCase):
    def test_sum_as_string(self) -> None:
        self.assertEqual("1379", pyo3_smoke.sum_as_string(1337, 42))


if __name__ == "__main__":
    unittest.main()
