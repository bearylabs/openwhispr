"""Guard the fork workflow's audit/functional separation without policy bypasses."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WorkflowSecurityTests(unittest.TestCase):
    def test_audit_is_an_independent_failing_gate_on_the_same_sha(self):
        workflow = (ROOT / '.github/workflows/tests.yml').read_text()
        security = workflow.split('\n  security:\n', 1)[1].split('\n  mobile:\n', 1)[0]
        self.assertIn('needs: resolve', security)
        self.assertIn('ref: ${{ needs.resolve.outputs.sha }}', security)
        self.assertIn('audit-ci --config audit-ci.json', security)
        self.assertNotIn('continue-on-error', security)
        self.assertNotIn('||', security)
        self.assertNotIn('--allowlist', security)
        self.assertNotIn('if:', security)
        self.assertEqual(workflow.count('audit-ci --config audit-ci.json'), 1)

    def test_functional_jobs_are_not_gated_by_audit(self):
        workflow = (ROOT / '.github/workflows/tests.yml').read_text()
        mobile = workflow.split('\n  mobile:\n', 1)[1].split('\n  native:\n', 1)[0]
        self.assertIn('needs: resolve', mobile)
        self.assertNotIn('needs: security', mobile)
        self.assertIn('ref: ${{ needs.resolve.outputs.sha }}', mobile)
        self.assertIn('check: [static, tests, bundles]', mobile)
        self.assertIn('patch-package --error-on-fail', mobile)
        self.assertIn('npm run test:security', mobile)
        self.assertIn('lockfile-lint', mobile)


if __name__ == '__main__':
    unittest.main()
