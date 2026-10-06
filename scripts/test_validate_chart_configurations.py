"""Run with: python3 -m unittest discover -s scripts -p 'test_validate_chart_configurations.py'."""

import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

import yaml

spec = importlib.util.spec_from_file_location("chart_check", Path(__file__).with_name("validate-chart-configurations.py"))
chart_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chart_check)


class ChartConfigurationChecks(unittest.TestCase):
    def test_probes_use_allowed_values(self):
        self.assertEqual(chart_check.changed_value({"type": "select", "options": ["INFO", "DEBUG"]}, "INFO", 0), "DEBUG")
        self.assertEqual(chart_check.changed_value({"type": "integer", "min": 1, "max": 5}, 5, 0), 4)
        self.assertEqual(chart_check.changed_value({"type": "integer", "min": 1}, "60", 0), "61")
        self.assertEqual(chart_check.changed_value({"type": "boolean"}, False, 0), True)
        self.assertEqual(chart_check.changed_value({"type": "boolean"}, "true", 0), "false")

    def test_configmap_must_reach_a_container(self):
        manifests = """
kind: ConfigMap
metadata: {name: settings}
data: {GOAL: probe}
---
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: agent
          env: []
"""
        self.assertEqual(chart_check.configured_environment(manifests, "GOAL"), [])
        doc = list(yaml.safe_load_all(manifests))
        container = doc[1]["spec"]["template"]["spec"]["containers"][0]
        container["envFrom"] = [{"configMapRef": {"name": "settings"}}]
        self.assertEqual(chart_check.configured_environment(yaml.safe_dump_all(doc), "GOAL"), ["probe"])
        container["env"] = [{"name": "GOAL", "value": "overridden"}]
        self.assertEqual(chart_check.configured_environment(yaml.safe_dump_all(doc), "GOAL"), ["overridden"])

    @unittest.skipUnless(shutil.which("helm"), "helm is required")
    def test_new_agent_setting_needs_no_template_changes(self):
        root = Path(__file__).resolve().parent.parent / "agent-charts" / "charts"
        for name in ("flash-agent", "sre-agent-comprehensive", "sre-agent-crewai"):
            with self.subTest(chart=name), tempfile.TemporaryDirectory() as tmp:
                chart = Path(tmp) / "chart"
                shutil.copytree(root / name, chart)
                values_file = chart / "values.yaml"
                values = yaml.safe_load(values_file.read_text())
                values["agent"]["config"]["CUSTOM_REACTION_POLICY"] = "original"
                values["configurations"] = [{"key": "agent.config.CUSTOM_REACTION_POLICY", "type": "string"}]
                values_file.write_text(yaml.safe_dump(values))
                self.assertEqual(chart_check.check_chart(chart, Path(tmp)), [])
                baseline = list(yaml.safe_load_all(chart_check.render(chart)))
                values["agent"]["config"]["CUSTOM_REACTION_POLICY"] = "changed"
                values_file.write_text(yaml.safe_dump(values))
                changed = list(yaml.safe_load_all(chart_check.render(chart)))
                def checksum(docs):
                    deployment = next(doc for doc in docs if doc and doc.get("kind") == "Deployment")
                    return deployment["spec"]["template"]["metadata"]["annotations"]["checksum/config"]
                self.assertNotEqual(checksum(baseline), checksum(changed), "a settings change must restart existing agent pods")


if __name__ == "__main__":
    unittest.main()
