"""Regression checks for interval-based CPU measurements"""

import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from .analyze import Table, resource_summary
from .performance import write_report


class ResourceSummaryTests(unittest.TestCase):
    def summarize(self, samples):
        root = ET.Element("trace-query-result")
        for start, duration, cpu in samples:
            row = ET.SubElement(root, "row")
            for tag, value in [("pid", 42), ("start-time", start * 1e9),
                               ("duration", duration * 1e9 if duration is not None else None),
                               ("system-cpu-percent", cpu)]:
                cell = ET.SubElement(row, tag if value is not None else "sentinel")
                if value is not None:
                    cell.text = str(value)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resources.xml"
            ET.ElementTree(root).write(path)
            return resource_summary(Table(path, ["pid", "start", "duration", "cpu-percent"]), 42)

    def test_unequal_intervals_use_native_cpu_and_current_duration(self):
        result = self.summarize([(0, .5, None), (.5, 2, 20), (2.5, .5, 80)])
        self.assertEqual(result["cpu_mean"], 32)
        self.assertEqual(result["cpu_p50"], 50)
        self.assertEqual(result["cpu_p95"], 77)
        self.assertEqual(result["cpu_peak"], 80)
        self.assertEqual(result["series"][1]["dt"], 2)
        self.assertAlmostEqual(result["cpu_coverage"], 2.5 / 3)
        self.assertEqual(result["errors"], [])

    def test_first_sample_and_multicore_cpu_are_retained(self):
        result = self.summarize([(0, 1, 200), (1, 1, 0), (2, 1, 100)])
        self.assertEqual(result["cpu_mean"], 100)
        self.assertEqual(result["cpu_peak"], 200)
        self.assertEqual(result["cpu_coverage"], 1)

    def test_missing_and_nonfinite_cpu_are_not_zero(self):
        for missing in [None, float("nan"), float("inf")]:
            with self.subTest(missing=missing):
                result = self.summarize([(0, 1, 20), (1, 2, missing), (3, 1, 40)])
                self.assertEqual(result["cpu_mean"], 30)
                self.assertEqual(result["cpu_coverage"], .5)
                self.assertIsNone(result["series"][1]["cpu"])

    def test_gap_reduces_coverage(self):
        result = self.summarize([(0, 1, 20), (2, 1, 20), (3, 1, 20)])
        self.assertEqual(result["cpu_coverage"], .75)

    def test_invalid_duration_is_rejected(self):
        for duration in [None, 0, -1, float("inf")]:
            with self.subTest(duration=duration):
                result = self.summarize([(0, 1, 20), (1, duration, 90), (2, 1, 20)])
                self.assertEqual(result["cpu_mean"], 20)
                self.assertIsNone(result["series"][1]["cpu"])
                self.assertTrue(result["errors"])

    def test_overlapping_intervals_and_negative_cpu_are_rejected(self):
        for middle in [(1, 2, 90), (2, 1, -10)]:
            with self.subTest(middle=middle):
                result = self.summarize([(0, 2, 20), middle, (3, 1, 20)])
                self.assertEqual(result["cpu_mean"], 20)
                self.assertIsNone(result["series"][1]["cpu"])
                self.assertTrue(result["errors"])

    def test_all_missing_cpu_stays_unavailable(self):
        result = self.summarize([(0, 1, None), (1, 1, None), (2, 1, None)])
        self.assertIsNone(result["cpu_mean"])
        self.assertIsNone(result["cpu_peak"])
        self.assertEqual(result["cpu_coverage"], 0)

    def test_report_mean_uses_valid_cpu_duration(self):
        phases = [
            {"id": "a", "template": "Activity Monitor", "resources":
             self.summarize([(0, 1, None), (1, 1, 10), (2, 1, 10)])},
            {"id": "b", "template": "Activity Monitor", "resources":
             self.summarize([(0, 1, None), (1, 2, 20), (3, 2, 20)])},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.html"
            write_report({"state": "complete", "phases": phases}, path)
            self.assertIn('16.67<span class="unit">%</span>', path.read_text())


if __name__ == "__main__":
    unittest.main()
